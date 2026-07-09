open! Core
open! Async
open Jsip_types
open Jsip_order_book

module Connection_state = struct
  (* Everything the server knows about one TCP connection. [addr] and [conn]
     are captured at connect time so stats can attribute per-connection
     buffering ([Rpc.Connection.bytes_to_write]) to a peer even if the
     connection never logs in. *)
  type t =
    { mutable session : Session.t option
    ; addr : Socket.Address.Inet.t
    ; conn : Rpc.Connection.t
    }

  let participant t = Option.map t.session ~f:Session.participant
end

module Loop_timing = struct
  (* Max observed gap between successive matching-loop iterations since the
     last stats read; see
     [Exchange_stats.Engine.max_gap_since_last_snapshot]. *)
  type t =
    { mutable last_iteration : Time_ns.t option
    ; mutable max_gap : Time_ns.Span.t
    }

  let create () = { last_iteration = None; max_gap = Time_ns.Span.zero }

  let record_iteration t ~now =
    (match t.last_iteration with
     | None -> ()
     | Some last ->
       let gap = Time_ns.diff now last in
       if Time_ns.Span.( > ) gap t.max_gap then t.max_gap <- gap);
    t.last_iteration <- Some now
  ;;

  let take_max_gap t =
    let max_gap = t.max_gap in
    t.max_gap <- Time_ns.Span.zero;
    max_gap
  ;;
end

(* The mutable state the stats snapshot reads, bundled so the stats RPC
   handler can close over it inside [start] before the full [t] exists. *)
module Stats_source = struct
  type t =
    { engine : Matching_engine.t
    ; dispatcher : Dispatcher.t
    ; registry : Participant_registry.t
    ; request_reader : Order.Request.t Pipe.Reader.t
    ; symbols : Symbol.t list
    ; connections : Connection_state.t Bag.t
    ; submits : int Participant_id.Table.t
    ; timing : Loop_timing.t
    }
end

type t =
  { engine : Matching_engine.t
  ; dispatcher : Dispatcher.t
  ; request_writer : Order.Request.t Pipe.Writer.t
  ; tcp_server : (Socket.Address.Inet.t, int) Tcp.Server.t
  ; port : int
  ; stats_source : Stats_source.t
  }

(* Bound how many client requests can sit in the queue waiting for the
   matching engine. Once the queue is full, [Pipe.write] returns a pending
   deferred and the [submit_order_rpc] handler blocks until the engine has
   processed enough requests to free up space — clients get backpressure
   without the server's memory growing unboundedly. *)
let request_queue_size_budget = 1024

(* Bound how many unread events any single subscriber pipe may hold before
   the dispatcher evicts the subscriber (see [Dispatcher]'s module comment).
   Sizing: the full audit firehose under the [slow-consumers] scenario runs
   at roughly 2_000 events/sec (measured 2026-07-07), so 10_000 gives even a
   full-firehose subscriber ~5 seconds to recover from a stall before the
   exchange protects itself, while capping the worst-case buffer at a few MB
   per subscriber. *)
let subscriber_pipe_size_budget = 10_000

let handle_submit ~request_writer (request : Order.Request.t) =
  let%map () = Pipe.write_if_open request_writer request in
  Ok ()
;;

let start_matching_loop
  ~engine
  ~dispatcher
  ~registry
  ~submits
  ~timing
  request_reader
  =
  don't_wait_for
    (Pipe.iter_without_pushback request_reader ~f:(fun request ->
       Loop_timing.record_iteration timing ~now:(Time_ns.now ());
       let participant_id =
         Participant_registry.intern
           registry
           request.Order.Request.participant
       in
       Hashtbl.incr submits participant_id;
       let events = Matching_engine.submit engine request in
       Dispatcher.dispatch dispatcher events))
;;

(* Each helper below gathers one metric family for the stats snapshot below.
   All are read-only except [engine_row], which resets the max-gap
   accumulator. *)

let subscriber_rows (source : Stats_source.t) =
  Dispatcher.subscriber_stats source.dispatcher
;;

let connection_rows (source : Stats_source.t) =
  Bag.to_list source.connections
  |> List.map ~f:(fun (state : Connection_state.t) ->
    { Exchange_stats.Connection.peer =
        Socket.Address.Inet.to_string state.addr
    ; participant = Connection_state.participant state
    ; bytes_to_write = Rpc.Connection.bytes_to_write state.conn
    })
;;

(* Family B comes in two halves with different key sets: [submit_counts]
   knows everyone who ever submitted; [resting_counts] knows everyone with
   orders in a book right now. Merging them into one row per participant is
   [snapshot]'s job. *)

let submit_counts (source : Stats_source.t) =
  Hashtbl.to_alist source.submits
  |> List.map ~f:(fun (id, count) ->
    Participant_registry.name source.registry id, count)
  |> Participant.Map.of_alist_exn
;;

let resting_counts (source : Stats_source.t) =
  List.fold
    source.symbols
    ~init:Participant.Map.empty
    ~f:(fun counts symbol ->
      match Matching_engine.book source.engine symbol with
      | None -> counts
      | Some book ->
        let orders =
          Order_book.orders_on_side book Side.Buy
          @ Order_book.orders_on_side book Side.Sell
        in
        List.fold orders ~init:counts ~f:(fun counts order ->
          Map.update counts (Order.participant order) ~f:(function
            | None -> 1
            | Some count -> count + 1)))
;;

let symbol_rows (source : Stats_source.t) =
  List.filter_map source.symbols ~f:(fun symbol ->
    match Matching_engine.book source.engine symbol with
    | None -> None
    | Some book ->
      let depth side =
        Order_book.orders_on_side book side
        |> List.fold ~init:Size.zero ~f:(fun total order ->
          Size.( + ) total (Order.remaining_size order))
      in
      Some
        { Exchange_stats.Symbol_depth.symbol
        ; bbo = Order_book.best_bid_offer book
        ; bid_depth = depth Side.Buy
        ; ask_depth = depth Side.Sell
        })
;;

let engine_row (source : Stats_source.t) =
  { Exchange_stats.Engine.max_gap_since_last_snapshot =
      Loop_timing.take_max_gap source.timing
  ; request_queue_length = Pipe.length source.request_reader
  }
;;

let snapshot (source : Stats_source.t) : Exchange_stats.t =
  (* [submit_counts] and [resting_counts] have different key sets: a
     participant whose orders all filled appears only on the left, one with
     resting orders but no submits this session only on the right. A row is
     produced for anyone appearing in either map. *)
  let participants =
    Map.merge
      (submit_counts source)
      (resting_counts source)
      ~f:(fun ~key:participant counts ->
        let submits, resting_orders =
          match counts with
          | `Left submits -> submits, 0
          | `Right resting_orders -> 0, resting_orders
          | `Both (submits, resting_orders) -> submits, resting_orders
        in
        Some
          { Exchange_stats.Participant_activity.participant
          ; submits
          ; resting_orders
          })
    |> Map.data
  in
  { Exchange_stats.taken_at = Time_ns.now ()
  ; subscribers = subscriber_rows source
  ; connections = connection_rows source
  ; participants
  ; symbols = symbol_rows source
  ; engine = engine_row source
  ; events_dispatched = Dispatcher.events_dispatched source.dispatcher
  ; evictions = Dispatcher.evictions source.dispatcher
  }
;;

let start ~symbols ~port () =
  let engine = Matching_engine.create symbols in
  let registry = Participant_registry.create () in
  let dispatcher =
    Dispatcher.create
      ~subscriber_pipe_budget:subscriber_pipe_size_budget
      ~registry
      ()
  in
  let request_reader, request_writer = Pipe.create () in
  Pipe.set_size_budget request_writer request_queue_size_budget;
  let connections = Bag.create () in
  let submits = Participant_id.Table.create () in
  let timing = Loop_timing.create () in
  let stats_source =
    { Stats_source.engine
    ; dispatcher
    ; registry
    ; request_reader
    ; symbols
    ; connections
    ; submits
    ; timing
    }
  in
  start_matching_loop
    ~engine
    ~dispatcher
    ~registry
    ~submits
    ~timing
    request_reader;
  let implementations =
    Rpc.Implementations.create_exn
      ~implementations:
        [ Rpc.Rpc.implement
            Rpc_protocol.login_rpc
            (fun connection_state name ->
               match String.strip name with
               | "" ->
                 return
                   (Error
                      (Error.of_string "participate name cannot be empty"))
               | stripped_name ->
                 let participant = Participant.of_string stripped_name in
                 let id = Participant_registry.intern registry participant in
                 let%bind.Deferred.Or_error session =
                   match Hashtbl.mem (Dispatcher.sessions dispatcher) id with
                   | true ->
                     return
                       (Error
                          (Error.of_string
                             "participant is already in a session"))
                   | false ->
                     Dispatcher.set_up_session dispatcher id |> Deferred.ok
                 in
                 connection_state.Connection_state.session <- Some session;
                 return (Ok participant))
        ; Rpc.Rpc.implement
            Rpc_protocol.submit_order_rpc
            (fun connection_state request ->
               match connection_state.Connection_state.session with
               | None -> return (Error (Error.of_string "not logged in"))
               | Some session ->
                 let request =
                   { request with participant = Session.participant session }
                 in
                 handle_submit ~request_writer request)
        ; Rpc.Rpc.implement
            Rpc_protocol.cancel_order_rpc
            (fun connection_state client_order_id ->
               match connection_state.Connection_state.session with
               | None -> return (Error (Error.of_string "not logged in"))
               | Some session ->
                 let participant = Session.participant session in
                 let events =
                   Matching_engine.cancel
                     engine
                     ~participant
                     ~client_order_id
                 in
                 Dispatcher.dispatch dispatcher events;
                 return (Ok ()))
        ; Rpc.Rpc.implement' Rpc_protocol.book_query_rpc (fun state symbol ->
            ignore state;
            Matching_engine.book engine symbol
            |> Option.map ~f:Order_book.snapshot)
        ; Rpc.Pipe_rpc.implement
            Rpc_protocol.market_data_rpc
            (fun (state : Connection_state.t) symbols ->
               let peer = Socket.Address.Inet.to_string state.addr in
               let reader =
                 Dispatcher.subscribe_market_data
                   dispatcher
                   symbols
                   ~label:[%string "market-data:%{peer}"]
               in
               return (Ok reader))
        ; Rpc.Pipe_rpc.implement
            Rpc_protocol.audit_log_rpc
            (fun (state : Connection_state.t) () ->
               let peer = Socket.Address.Inet.to_string state.addr in
               let reader =
                 Dispatcher.subscribe_audit
                   dispatcher
                   ~label:[%string "audit:%{peer}"]
               in
               return (Ok reader))
        ; Rpc.Rpc.implement'
            Rpc_protocol.exchange_stats_rpc
            (fun (state : Connection_state.t) () ->
               ignore (state : Connection_state.t);
               snapshot stats_source)
        ; Rpc.Pipe_rpc.implement
            Rpc_protocol.session_feed_rpc
            (fun connection_state () ->
               match connection_state.Connection_state.session with
               | None -> return (Error (Error.of_string "not logged in"))
               | Some session -> return (Ok (Session.reader session)))
        ]
      ~on_unknown_rpc:`Close_connection
      ~on_exception:Log_on_background_exn
  in
  let%map tcp_server =
    Rpc.Connection.serve
      ~implementations
      ~initial_connection_state:(fun addr conn ->
        let connection_state =
          { Connection_state.session = None; addr; conn }
        in
        let elt = Bag.add connections connection_state in
        don't_wait_for
          (let%bind () = Rpc.Connection.close_finished conn in
           Bag.remove connections elt;
           match connection_state.session with
           | None -> return ()
           | Some session -> Dispatcher.clean_up_session dispatcher session);
        connection_state)
      ~where_to_listen:(Tcp.Where_to_listen.of_port port)
      ()
  in
  let actual_port = Tcp.Server.listening_on tcp_server in
  { engine
  ; dispatcher
  ; request_writer
  ; tcp_server
  ; port = actual_port
  ; stats_source
  }
;;

let port t = t.port

let close t =
  Pipe.close t.request_writer;
  Tcp.Server.close t.tcp_server
;;

let close_finished t = Tcp.Server.close_finished t.tcp_server
let stats t = snapshot t.stats_source
