open! Core
open! Async
open Jsip_types

(* A feed pipe plus a human-readable identity for stats attribution. The
   label is chosen at the subscribe call site, where the subscriber's
   identity (e.g. the RPC connection's peer address) is in scope. *)
type subscriber =
  { writer : Exchange_event.t Pipe.Writer.t
  ; label : string
  }

type t =
  { market_data_subscribers_by_symbol :
      Exchange_event.t Pipe.Writer.t Bag.t Symbol.Table.t
      (* Delivery path: per-symbol bags of bare writers; the same writer
         appears in every bag it subscribed to. *)
  ; market_data_subscribers : subscriber Bag.t
      (* Stats path: exactly one entry per market-data subscriber, however
         many symbol bags its writer sits in. Folding over the per-symbol
         bags instead would count a multi-symbol subscriber once per symbol. *)
  ; audit_subscribers : subscriber Bag.t
  ; sessions : Session.t Participant.Table.t
  ; subscriber_pipe_budget : int
  ; mutable events_dispatched : int
  ; mutable evictions : int
  }

let sessions t = t.sessions

let create ~subscriber_pipe_budget () =
  { market_data_subscribers_by_symbol = Symbol.Table.create ()
  ; market_data_subscribers = Bag.create ()
  ; audit_subscribers = Bag.create ()
  ; sessions = Participant.Table.create ()
  ; subscriber_pipe_budget
  ; events_dispatched = 0
  ; evictions = 0
  }
;;

(* The exchange never blocks on a slow subscriber ([dispatch] runs on the
   matching loop), so when a pipe hits the budget the only safe move is to
   disconnect it: close the writer, let the existing [Pipe.closed] cleanup
   unregister it, and count the eviction. *)
let write_or_evict t writer event =
  if Pipe.length writer >= t.subscriber_pipe_budget
  then (
    t.evictions <- t.evictions + 1;
    Pipe.close writer)
  else Pipe.write_without_pushback_if_open writer event
;;

let subscribe_market_data t symbols ~label =
  let reader, writer = Pipe.create () in
  let registry_elt = Bag.add t.market_data_subscribers { writer; label } in
  (* Register the same writer in every requested symbol's bag. A per-symbol
     publish iterates a single bag, so a subscriber listed in multiple bags
     receives each event exactly once — only via whichever bag matches the
     event's symbol. *)
  let elts =
    List.map symbols ~f:(fun symbol ->
      let subscribers =
        Hashtbl.find_or_add
          t.market_data_subscribers_by_symbol
          ~default:Bag.create
          symbol
      in
      symbol, Bag.add subscribers writer)
  in
  don't_wait_for
    (let%map () = Pipe.closed writer in
     Bag.remove t.market_data_subscribers registry_elt;
     List.iter elts ~f:(fun (symbol, elt) ->
       match Hashtbl.find t.market_data_subscribers_by_symbol symbol with
       | None -> ()
       | Some subscribers -> Bag.remove subscribers elt));
  reader
;;

let subscribe_audit t ~label =
  let reader, writer = Pipe.create () in
  let elt = Bag.add t.audit_subscribers { writer; label } in
  don't_wait_for
    (let%map () = Pipe.closed writer in
     Bag.remove t.audit_subscribers elt);
  reader
;;

let push_market_data t event symbol =
  match Hashtbl.find t.market_data_subscribers_by_symbol symbol with
  | None -> ()
  | Some subscribers ->
    Bag.iter subscribers ~f:(fun writer -> write_or_evict t writer event)
;;

let push_audit t event =
  Bag.iter t.audit_subscribers ~f:(fun { writer; label = _ } ->
    write_or_evict t writer event)
;;

let push_to_session t participant event =
  match Hashtbl.find t.sessions participant with
  | None -> ()
  | Some session ->
    if Session.backlog session >= t.subscriber_pipe_budget
    then (
      t.evictions <- t.evictions + 1;
      Session.close session)
    else Session.push session event
;;

let clean_up_session t (session : Session.t) =
  let participant = Session.participant session in
  Hashtbl.remove t.sessions participant;
  Session.close session;
  return ()
;;

let set_up_session t (participant : Participant.t) =
  match Hashtbl.find t.sessions participant with
  | None ->
    let session = Session.create participant in
    Hashtbl.set t.sessions ~key:participant ~data:session;
    return session
  | Some existing_session ->
    let%bind () = clean_up_session t existing_session in
    let session = Session.create participant in
    Hashtbl.set t.sessions ~key:participant ~data:session;
    return session
;;

let dispatch_event t (event : Exchange_event.t) =
  t.events_dispatched <- t.events_dispatched + 1;
  push_audit t event;
  match event with
  | Best_bid_offer_update { symbol; bbo = _ } ->
    push_market_data t event symbol
  | Trade_report { symbol; price = _; size = _ } ->
    push_market_data t event symbol
  | Order_accept { order_id = _; request }
  | Order_reject { request; reason = _ } ->
    push_to_session t request.participant event
  | Order_cancel
      { order_id = _
      ; participant
      ; symbol = _
      ; remaining_size = _
      ; reason = _
      ; client_order_id = _
      } ->
    push_to_session t participant event
  | Fill
      { fill_id = _
      ; symbol = _
      ; price = _
      ; size = _
      ; aggressor_order_id = _
      ; aggressor_participant
      ; aggressor_side = _
      ; resting_order_id = _
      ; resting_participant
      ; aggressor_client_order_id = _
      ; resting_client_order_id = _
      } ->
    push_to_session t aggressor_participant event;
    push_to_session t resting_participant event
  | Cancel_reject { participant; client_order_id = _; reason = _ } ->
    push_to_session t participant event
;;

let dispatch t events = List.iter events ~f:(dispatch_event t)
let events_dispatched t = t.events_dispatched
let evictions t = t.evictions

let subscriber_stats t : Exchange_stats.Subscriber.t list =
  let of_subscriber { writer; label } : Exchange_stats.Subscriber.t =
    { label; pipe_length = Pipe.length writer }
  in
  let of_session session : Exchange_stats.Subscriber.t =
    let participant = Session.participant session in
    { label = [%string "session:%{participant#Participant}"]
    ; pipe_length = Session.backlog session
    }
  in
  List.concat
    [ Bag.to_list t.market_data_subscribers |> List.map ~f:of_subscriber
    ; Bag.to_list t.audit_subscribers |> List.map ~f:of_subscriber
    ; Hashtbl.data t.sessions |> List.map ~f:of_session
    ]
;;

module For_testing = struct
  let audit_subscriber_count t = Bag.length t.audit_subscribers
end
