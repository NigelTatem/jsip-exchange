open! Core
open Jsip_types

module OrderKey = struct
  type t = Price.t * Order_id.t [@@deriving compare, sexp]

  include functor Comparable.Make
end

type t =
  { symbol : Symbol_id.t
  ; mutable bids : Order.t OrderKey.Map.t
  ; mutable asks : Order.t Map.M(OrderKey).t
  ; mutable order_ids : (Price.t * Side.t) Map.M(Order_id).t
  }
[@@deriving sexp_of]

let create symbol =
  { symbol
  ; bids = Map.empty (module OrderKey)
  ; asks = Map.empty (module OrderKey)
  ; order_ids = Map.empty (module Order_id)
  }
;;

let symbol t = t.symbol

let side_map t side =
  match (side : Side.t) with Buy -> t.bids | Sell -> t.asks
;;

let set_side_map t side orders =
  match (side : Side.t) with
  | Buy -> t.bids <- orders
  | Sell -> t.asks <- orders
;;

let add t order =
  let side = Order.side order in
  let price = Order.price order in
  let id = Order.order_id order in
  set_side_map
    t
    side
    (Map.set (side_map t side) ~key:(price, id) ~data:order);
  t.order_ids <- Map.set t.order_ids ~key:id ~data:(price, side)
;;

let remove' t order_id =
  match Map.find t.order_ids order_id with
  | None -> None
  | Some (price, side) ->
    let key = price, order_id in
    let target_map = side_map t side in
    let found_order = Map.find target_map key in
    set_side_map t side (Map.remove target_map key);
    t.order_ids <- Map.remove t.order_ids order_id;
    found_order
;;

let remove t order_id = ignore (remove' t order_id : Order.t option)

let find t order_id =
  match Map.find t.order_ids order_id with
  | None -> None
  | Some (price, side) ->
    let key = price, order_id in
    let target_map = side_map t side in
    Map.find target_map key
;;

let best_resting_entry t side =
  let resting_orders = side_map t side in
  match side with
  | Side.Sell -> Map.min_elt resting_orders
  | Side.Buy ->
    (match Map.max_elt resting_orders with
     | None -> None
     | Some ((price, _), _) ->
       Map.closest_key
         resting_orders
         `Greater_or_equal_to
         (price, Order_id.For_testing.of_int 0))
;;

let find_match t (incoming_order : Order.t) : Order.t option =
  let incoming_side = Order.side incoming_order in
  let opposite_side = Side.flip incoming_side in
  let best_resting_entry = best_resting_entry t opposite_side in
  match best_resting_entry with
  | None -> None
  | Some (_key, resting) ->
    (match
       Price.is_marketable
         incoming_side
         ~price:(Order.price incoming_order)
         ~resting_price:(Order.price resting)
     with
     | true -> Some resting
     | false -> None)
;;

let orders_on_side t side = Map.data (side_map t side)
let is_empty t = Map.is_empty t.bids && Map.is_empty t.asks
let count t side = Map.length (side_map t side)

(* account for the fact that order_id may be backwards since we want lowest
   and there may be no test cases exposing this flaw *)
let best_level t side : Level.t option =
  let best_resting_entry = best_resting_entry t side in
  let current_map = side_map t side in
  match best_resting_entry with
  | None -> None
  | Some (_first_key, best_order) ->
    let price = Order.price best_order in
    (match
       Map.closest_key
         current_map
         `Greater_or_equal_to
         (price, Order_id.For_testing.of_int 0)
     with
     | None -> None
     | Some (start_key, _) ->
       let total_size =
         Map.to_sequence current_map ~keys_greater_or_equal_to:start_key
         |> Sequence.take_while ~f:(fun ((p, _), _) -> Price.equal p price)
         |> Sequence.fold ~init:Size.zero ~f:(fun acc (_, order) ->
           Size.( + ) acc (Order.remaining_size order))
       in
       Some { price; size = total_size })
;;

let best_bid_offer t : Bbo.t =
  { bid = best_level t Buy; ask = best_level t Sell }
;;

let snapshot_side t (side : Side.t) =
  (* The map is keyed ascending by [(price, order_id)], so orders at the same
     price are adjacent: one fold merges each run of equal prices into a
     single aggregated level. Consing while folding ascending yields a
     descending (best-first) list for bids; asks are reversed back to
     ascending. *)
  let descending =
    Map.fold (side_map t side) ~init:[] ~f:(fun ~key:_ ~data:order levels ->
      let order_level = Level.of_order order in
      match levels with
      | { Level.price; size } :: rest
        when Price.equal price order_level.price ->
        { Level.price; size = Size.( + ) size order_level.size } :: rest
      | _ -> order_level :: levels)
  in
  match side with Buy -> descending | Sell -> List.rev descending
;;

let snapshot t =
  { Book.symbol = symbol t
  ; bids = snapshot_side t Buy
  ; asks = snapshot_side t Sell
  ; bbo = best_bid_offer t
  }
;;

module For_testing = struct
  let remove = remove'
end
