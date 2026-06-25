open! Core
open! Async
open Jsip_types
open Jsip_order_book

type t =
  { engine : Matching_engine.t
  ; dispatcher : Dispatcher.t
  ; request_writer : Order.Request.t Pipe.Writer.t
  ; tcp_server : (Socket.Address.Inet.t, int) Tcp.Server.t
  ; port : int
  }

(* Bound how many client requests can sit in the queue waiting for the
   matching engine. Once the queue is full, [Pipe.write] returns a pending
   deferred and the [submit_order_rpc] handler blocks until the engine has
   processed enough requests to free up space — clients get backpressure
   without the server's memory growing unboundedly. *)
let request_queue_size_budget = 1024

let handle_submit ~request_writer (request : Order.Request.t) =
  let%map () = Pipe.write_if_open request_writer request in
  Ok ()
;;

let start_matching_loop ~engine ~dispatcher request_reader =
  don't_wait_for
    (Pipe.iter_without_pushback request_reader ~f:(fun request ->
       let events = Matching_engine.submit engine request in
       Dispatcher.dispatch dispatcher events))
;;

module Connection_state = struct
  type t = { mutable session : Session.t option }

  let _participant t = Option.map t.session ~f:Session.participant
end

let start ~symbols ~port () =
  let engine = Matching_engine.create symbols in
  let dispatcher = Dispatcher.create () in
  let request_reader, request_writer = Pipe.create () in
  Pipe.set_size_budget request_writer request_queue_size_budget;
  start_matching_loop ~engine ~dispatcher request_reader;
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
                 let%bind.Deferred.Or_error session =
                   match
                     Hashtbl.mem (Dispatcher.sessions dispatcher) participant
                   with
                   | true ->
                     return
                       (Error
                          (Error.of_string
                             "participant is already in a session"))
                   | false ->
                     Dispatcher.set_up_session dispatcher participant
                     |> Deferred.ok
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
        ; Rpc.Rpc.implement' Rpc_protocol.book_query_rpc (fun state symbol ->
            ignore state;
            Matching_engine.book engine symbol
            |> Option.map ~f:Order_book.snapshot)
        ; Rpc.Pipe_rpc.implement
            Rpc_protocol.market_data_rpc
            (fun state symbols ->
               ignore state;
               let reader =
                 Dispatcher.subscribe_market_data dispatcher symbols
               in
               return (Ok reader))
        ; Rpc.Pipe_rpc.implement Rpc_protocol.audit_log_rpc (fun state () ->
            ignore state;
            let reader = Dispatcher.subscribe_audit dispatcher in
            return (Ok reader))
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
      ~initial_connection_state:(fun _addr conn ->
        let connection_state = { Connection_state.session = None } in
        don't_wait_for
          (let%bind () = Rpc.Connection.close_finished conn in
           match connection_state.session with
           | None -> return ()
           | Some session -> Dispatcher.clean_up_session dispatcher session);
        connection_state)
      ~where_to_listen:(Tcp.Where_to_listen.of_port port)
      ()
  in
  let actual_port = Tcp.Server.listening_on tcp_server in
  { engine; dispatcher; request_writer; tcp_server; port = actual_port }
;;

let port t = t.port

let close t =
  Pipe.close t.request_writer;
  Tcp.Server.close t.tcp_server
;;

let close_finished t = Tcp.Server.close_finished t.tcp_server
