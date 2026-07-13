open! Core
open Jsip_types

(* could make this into its own module if neccessary *)
module Client_id_key = struct
  module T = struct
    type t = Participant.t * Client_order_id.t
    [@@deriving sexp, compare, hash]
  end

  include T
  include Hashable.Make (T)
end

type t =
  { books : Order_book.t array
  ; order_id_gen : Order_id.Generator.t
  ; mutable next_fill_id : int
  ; used_client_ids : Order.t Client_id_key.Table.t
  }
[@@deriving sexp_of]

(* One book per symbol id, indexed directly by the id. The client now sends
   the [Symbol_id.t] the engine used to hash for in Ex 2, so the name->id
   table is gone: [create] gives the symbol at position [i] the id [i]. *)
let create symbols =
  { books =
      List.mapi symbols ~f:(fun id (_ : Symbol_id.t) ->
        Order_book.create (Symbol_id.of_int id))
      |> Array.of_list
  ; order_id_gen = Order_id.Generator.create ()
  ; next_fill_id = 1
  ; used_client_ids = Client_id_key.Table.create ()
  }
;;

(* Bounds-checked lookup: an out-of-range id — e.g. a malformed one off the
   wire — yields [None] instead of raising. That check is the id validation
   the wire boundary needs. *)
let book t symbol_id =
  let index = Symbol_id.to_int symbol_id in
  if index >= 0 && index < Array.length t.books
  then Some t.books.(index)
  else None
;;

(** Run the matching loop: repeatedly find a compatible resting order and
    fill against it. Returns the list of Fill and Trade_report events
    produced, and the next fill_id to use. *)
let rec match_loop ~used_client_ids ~book ~order ~fill_id =
  if Size.( <= ) (Order.remaining_size order) Size.zero
  then [], fill_id
  else (
    match Order_book.find_match book order with
    | None -> [], fill_id
    | Some resting ->
      let fill_size =
        Size.min (Order.remaining_size order) (Order.remaining_size resting)
      in
      Order.fill order ~by:fill_size;
      (* Pull [resting] out of the book before mutating its size, then put it
         back if any size remains. Routing the size change through
         [remove]/[add] is what keeps each price level's cached [total_size]
         exact — an in-place [Order.fill] alone would leave the cache stale.
         Re-adding under the same [order_id] preserves the order's position
         in the level's FIFO queue. *)
      Order_book.remove book (Order.order_id resting);
      Order.fill resting ~by:fill_size;
      if Order.is_fully_filled resting
      then
        Hashtbl.remove
          used_client_ids
          (Order.participant resting, Order.client_order_id resting)
      else Order_book.add book resting;
      let fill_event =
        Exchange_event.Fill
          { fill_id
          ; symbol = Order.symbol order
          ; price = Order.price resting
          ; size = fill_size
          ; aggressor_order_id = Order.order_id order
          ; aggressor_participant = Order.participant order
          ; aggressor_side = Order.side order
          ; resting_order_id = Order.order_id resting
          ; resting_participant = Order.participant resting
          ; aggressor_client_order_id = Order.client_order_id order
          ; resting_client_order_id = Order.client_order_id resting
          }
      in
      let trade_event =
        Exchange_event.Trade_report
          { symbol = Order.symbol order
          ; price = Order.price resting
          ; size = fill_size
          }
      in
      let remaining_events, next_fill_id =
        match_loop ~used_client_ids ~book ~order ~fill_id:(fill_id + 1)
      in
      fill_event :: trade_event :: remaining_events, next_fill_id)
;;

let submit t (request : Order.Request.t) =
  match book t request.symbol with
  | None ->
    [ Exchange_event.Order_reject { request; reason = "unknown symbol" } ]
  | Some book ->
    (match
       Hashtbl.find
         t.used_client_ids
         (request.participant, request.client_order_id)
     with
     | Some _existing_order ->
       [ Exchange_event.Order_reject
           { request; reason = "duplicate client order id" }
       ]
     | None ->
       let order_id = Order_id.Generator.next t.order_id_gen in
       let order = Order.create request ~order_id in
       Hashtbl.set
         t.used_client_ids
         ~key:(request.participant, request.client_order_id)
         ~data:order;
       let accepted = Exchange_event.Order_accept { order_id; request } in
       (* Snapshot BBO before matching so we can detect changes. *)
       let bbo_before = Order_book.best_bid_offer book in
       (* Match *)
       let fill_events, next_fill_id =
         match_loop
           ~used_client_ids:t.used_client_ids
           ~book
           ~order
           ~fill_id:t.next_fill_id
       in
       t.next_fill_id <- next_fill_id;
       (* Post-match: rest on book or cancel unfilled remainder. *)
       let post_events =
         if Size.( > ) (Order.remaining_size order) Size.zero
         then (
           match Order.time_in_force order with
           | Day ->
             Order_book.add book order;
             []
           | Ioc ->
             [ Exchange_event.Order_cancel
                 { order_id
                 ; participant = Order.participant order
                 ; symbol = Order.symbol order
                 ; remaining_size = Order.remaining_size order
                 ; reason = Ioc_remainder
                 ; client_order_id = request.client_order_id
                 }
             ])
         else []
       in
       (* Emit BBO update if the best bid or ask changed. *)
       let bbo_after = Order_book.best_bid_offer book in
       let bbo_events =
         if Bbo.equal bbo_before bbo_after
         then []
         else
           [ Exchange_event.Best_bid_offer_update
               { symbol = Order.symbol order; bbo = bbo_after }
           ]
       in
       (* An order holds its client-order-id slot only while it is live. Free
          the slot if it did not come to rest (fully filled, or IOC remainder
          cancelled) so the id can be reused. *)
       if not
            (Size.( > ) (Order.remaining_size order) Size.zero
             && Time_in_force.rests_on_book (Order.time_in_force order))
       then
         Hashtbl.remove
           t.used_client_ids
           (request.participant, request.client_order_id);
       List.concat [ [ accepted ]; fill_events; post_events; bbo_events ])
;;

let cancel t ~participant ~client_order_id =
  match Hashtbl.find t.used_client_ids (participant, client_order_id) with
  | None ->
    [ Exchange_event.Cancel_reject
        { participant; client_order_id; reason = "unknown order" }
    ]
  | Some order ->
    let symbol = Order.symbol order in
    let order_id = Order.order_id order in
    let resting =
      let%bind.Option book = book t symbol in
      let%map.Option active_order = Order_book.find book order_id in
      book, active_order
    in
    (match resting with
     | None ->
       [ Exchange_event.Cancel_reject
           { participant; client_order_id; reason = "order not active" }
       ]
     | Some (book, _active_order) ->
       let bbo_before = Order_book.best_bid_offer book in
       Order_book.remove book order_id;
       Hashtbl.remove t.used_client_ids (participant, client_order_id);
       let cancel_event =
         Exchange_event.Order_cancel
           { order_id
           ; participant
           ; symbol
           ; remaining_size = Order.remaining_size order
           ; reason = Participant_requested
           ; client_order_id
           }
       in
       let bbo_after = Order_book.best_bid_offer book in
       let bbo_events =
         if Bbo.equal bbo_before bbo_after
         then []
         else
           [ Exchange_event.Best_bid_offer_update { symbol; bbo = bbo_after }
           ]
       in
       cancel_event :: bbo_events)
;;
