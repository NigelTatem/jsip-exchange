open! Core
open! Async
open Jsip_types
open Jsip_gateway

module Config = struct
  type t =
    { participant : Participant.t
    ; symbol : Symbol_id.t
    ; fair_value_cents : int
    ; half_spread_cents : int
    ; size_per_level : int
    ; num_levels : int
    ; inventory_skew_cents_per_share : int
    }
  [@@deriving sexp_of]
end

module Order_info = struct
  type t =
    { side : Side.t
    ; mutable remaining : int
    }
end

type state =
  { mutable inventory : int
  ; outstanding : Order_info.t Client_order_id.Table.t
  ; mutable next_id : int
  }

let create_state () =
  { inventory = 0
  ; outstanding = Client_order_id.Table.create ()
  ; next_id = 0
  }
;;

let fresh_id state =
  let id = state.next_id in
  state.next_id <- state.next_id + 1;
  id
;;

let submit_order conn (config : Config.t) ~side ~price ~client_order_id =
  let request : Order.Request.t =
    { symbol = config.symbol
    ; participant = config.participant
    ; side
    ; price
    ; size = Size.of_int config.size_per_level
    ; time_in_force = Day
    ; client_order_id
    }
  in
  let%map result =
    Rpc.Rpc.dispatch_exn Rpc_protocol.submit_order_rpc conn request
  in
  match result with
  | Ok () -> ()
  | Error msg ->
    [%log.error
      "market_maker: submit failed"
        (request : Order.Request.t)
        (msg : Error.t)]
;;

let submit_ladder conn config state =
  let skewed_fair =
    config.Config.fair_value_cents
    - (state.inventory * config.inventory_skew_cents_per_share)
  in
  Deferred.List.iter
    ~how:`Parallel
    (List.init config.num_levels ~f:Fn.id)
    ~f:(fun level ->
      let offset = config.half_spread_cents + level in
      let%bind () =
        submit_order
          conn
          config
          ~side:Buy
          ~price:(Price.of_int_cents (skewed_fair - offset))
          ~client_order_id:(fresh_id state)
      in
      submit_order
        conn
        config
        ~side:Sell
        ~price:(Price.of_int_cents (skewed_fair + offset))
        ~client_order_id:(fresh_id state))
;;

let handle_fill_side state ~fill_size ~client_order_id =
  match Hashtbl.find state.outstanding client_order_id with
  | None -> ()
  | Some info ->
    (match info.side with
     | Buy -> state.inventory <- state.inventory + fill_size
     | Sell -> state.inventory <- state.inventory - fill_size);
    info.remaining <- info.remaining - fill_size;
    if info.remaining <= 0
    then Hashtbl.remove state.outstanding client_order_id
;;

(* Unfinished *)
let handle_event state (event : Exchange_event.t) =
  match event with
  | Order_accept { request; _ } ->
    Hashtbl.set
      state.outstanding
      ~key:request.client_order_id
      ~data:
        { Order_info.side = request.side
        ; remaining = Size.to_int request.size
        }
  | Order_cancel { client_order_id; _ } ->
    Hashtbl.remove state.outstanding client_order_id
  | Fill fill ->
    let fill_size = Size.to_int fill.size in
    handle_fill_side
      state
      ~fill_size
      ~client_order_id:fill.aggressor_client_order_id;
    handle_fill_side
      state
      ~fill_size
      ~client_order_id:fill.resting_client_order_id
  | _ -> ()
;;

let seed_book (config : Config.t) conn =
  let next_id = ref 0 in
  let submit ~side ~price =
    let client_order_id = !next_id in
    next_id := !next_id + 1;
    let request : Order.Request.t =
      { symbol = config.symbol
      ; participant = config.participant
      ; side
      ; price
      ; size = Size.of_int config.size_per_level
      ; time_in_force = Day
      ; client_order_id
      }
    in
    let%map result =
      Rpc.Rpc.dispatch_exn Rpc_protocol.submit_order_rpc conn request
    in
    match result with
    | Ok () -> ()
    | Error msg ->
      [%log.error
        "market_maker: submit failed"
          (request : Order.Request.t)
          (msg : Error.t)]
  in
  Deferred.List.iter
    ~how:`Parallel
    (List.init config.num_levels ~f:Fn.id)
    ~f:(fun level ->
      let offset = config.half_spread_cents + level in
      let%bind () =
        submit
          ~side:Buy
          ~price:(Price.of_int_cents (config.fair_value_cents - offset))
      in
      submit
        ~side:Sell
        ~price:(Price.of_int_cents (config.fair_value_cents + offset)))
;;

let cancel_all_outstanding conn state =
  let ids = Hashtbl.keys state.outstanding in
  Deferred.List.iter ids ~how:`Parallel ~f:(fun client_order_id ->
    match%map
      Rpc.Rpc.dispatch_exn Rpc_protocol.cancel_order_rpc conn client_order_id
    with
    | Ok () -> ()
    | Error _err -> ())
;;

let run (config : Config.t) (conn : Rpc.Connection.t) : unit Deferred.t =
  let state = create_state () in
  let%bind _participant =
    Rpc.Rpc.dispatch_exn
      Rpc_protocol.login_rpc
      conn
      (Participant.to_string config.participant)
    >>| Or_error.ok_exn
  in
  let%bind session_feed, _metadata =
    Rpc.Pipe_rpc.dispatch_exn Rpc_protocol.session_feed_rpc conn ()
  in
  let%bind () = submit_ladder conn config state in
  let%bind () =
    Pipe.iter session_feed ~f:(fun event ->
      handle_event state event;
      match event with
      | Fill _ ->
        let%bind () = cancel_all_outstanding conn state in
        submit_ladder conn config state
      | _ -> Deferred.unit)
  in
  Deferred.never ()
;;
