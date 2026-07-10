open! Core
open! Async
open Jsip_types
module Bot_runtime = Jsip_bot_runtime.Bot_runtime

type order_status =
  | Pending
  | Open

type order_info =
  { side : Side.t
  ; price : Price.t
  ; mutable remaining : int
  ; mutable status : order_status
  }

type state =
  { mutable inventory : int
  ; outstanding : order_info Client_order_id.Table.t
  ; mutable next_id : int
  ; mutable has_seeded : bool
  }

module Config = struct
  type t =
    { symbol : Symbol_id.t
    ; half_spread_cents : int
    ; size_per_level : int
    ; num_levels : int
    ; inventory_skew_cents_per_share : int
    ; state_id : string
    }
  [@@deriving sexp_of]
end

let config_counter = ref 0
let registry : state String.Table.t = String.Table.create ()

let create_config
  ~symbol
  ~half_spread_cents
  ~size_per_level
  ~num_levels
  ~inventory_skew_cents_per_share
  =
  let id = !config_counter in
  config_counter := id + 1;
  { Config.symbol
  ; half_spread_cents
  ; size_per_level
  ; num_levels
  ; inventory_skew_cents_per_share
  ; state_id = "bot_" ^ string_of_int id
  }
;;

let get_state (config : Config.t) =
  Hashtbl.find_or_add registry config.state_id ~default:(fun () ->
    { inventory = 0
    ; outstanding = Client_order_id.Table.create ()
    ; next_id = 0
    ; has_seeded = false
    })
;;

let name = "Market_maker_bot"

let fresh_id (config : Config.t) =
  let state = get_state config in
  let id = state.next_id in
  state.next_id <- state.next_id + 1;
  id
;;

let submit_order ctx (config : Config.t) ~side ~price ~client_order_id =
  let state = get_state config in
  let request : Order.Request.t =
    { symbol = config.symbol
    ; participant = Bot_runtime.Context.participant ctx
    ; side
    ; price
    ; size = Size.of_int config.size_per_level
    ; time_in_force = Day
    ; client_order_id
    }
  in
  Hashtbl.set
    state.outstanding
    ~key:client_order_id
    ~data:
      { side; price; remaining = config.size_per_level; status = Pending };
  match%map Bot_runtime.Context.submit ctx request with
  | Ok () -> ()
  | Error msg ->
    Hashtbl.remove state.outstanding client_order_id;
    [%log.error
      "market_maker_bot: submit failed"
        (request : Order.Request.t)
        (msg : Error.t)]
;;

let cancel_all_outstanding ctx (config : Config.t) =
  let state = get_state config in
  let ids = Hashtbl.keys state.outstanding in
  Deferred.List.iter ids ~how:`Parallel ~f:(fun client_order_id ->
    match%map Bot_runtime.Context.cancel ctx client_order_id with
    | Ok () -> ()
    | Error _err -> ())
;;

let submit_ladder ctx (config : Config.t) =
  let state = get_state config in
  let fair_price = Bot_runtime.Context.fundamental ctx config.symbol in
  let fair_cents = Price.to_int_cents fair_price in
  let skewed_fair =
    fair_cents - (state.inventory * config.inventory_skew_cents_per_share)
  in
  Deferred.List.iter
    ~how:`Parallel
    (List.init config.num_levels ~f:Fn.id)
    ~f:(fun level ->
      let offset = config.half_spread_cents + level in
      let%bind () =
        submit_order
          ctx
          config
          ~side:Buy
          ~price:(Price.of_int_cents (skewed_fair - offset))
          ~client_order_id:(fresh_id config)
      in
      submit_order
        ctx
        config
        ~side:Sell
        ~price:(Price.of_int_cents (skewed_fair + offset))
        ~client_order_id:(fresh_id config))
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

let handle_bot_event state (event : Exchange_event.t) =
  match event with
  | Order_accept { request; _ } ->
    (match Hashtbl.find state.outstanding request.client_order_id with
     | Some info -> info.status <- Open
     | None -> ())
  | Order_reject { request; _ } ->
    Hashtbl.remove state.outstanding request.client_order_id
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

let on_start (config : Config.t) (ctx : Bot_runtime.Context.t)
  : unit Deferred.t
  =
  let state = get_state config in
  if not state.has_seeded
  then (
    state.has_seeded <- true;
    submit_ladder ctx config)
  else Deferred.unit
;;

let on_tick (config : Config.t) (ctx : Bot_runtime.Context.t)
  : unit Deferred.t
  =
  let state = get_state config in
  if not state.has_seeded
  then Deferred.unit
  else (
    let%bind () = cancel_all_outstanding ctx config in
    submit_ladder ctx config)
;;

let on_event
  (config : Config.t)
  (ctx : Bot_runtime.Context.t)
  (event : Exchange_event.t)
  : unit Deferred.t
  =
  let state = get_state config in
  handle_bot_event state event;
  match event with
  | Fill _ ->
    let%bind () = cancel_all_outstanding ctx config in
    submit_ladder ctx config
  | _ -> Deferred.unit
;;
