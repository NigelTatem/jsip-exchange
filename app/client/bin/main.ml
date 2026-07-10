(** Exchange client.

    Connects to a running exchange server and provides an interactive
    command-line interface for submitting orders and querying the book.

    Run with: dune exec app/client/bin/main.exe -- -host localhost -port
    12345 -name Alice *)

open! Core
open! Async
open Jsip_types
open Jsip_gateway

let run_client ~host ~port ~participant_name =
  let where_to_connect =
    Tcp.Where_to_connect.of_host_and_port { host; port }
  in
  let%bind conn = Rpc.Connection.client where_to_connect >>| Result.ok_exn in
  (* Fetch the symbol directory once at connect and mirror it locally. From
     here on the wire carries ids; this mirror is how we turn names the human
     types into ids (at parse) and ids the server sends back into names (at
     render). *)
  let%bind directory =
    Rpc.Rpc.dispatch_exn Rpc_protocol.symbol_directory_rpc conn ()
    >>| Symbol_directory.of_pairs
  in
  let render_symbol = Symbol_directory.render directory in
  let%bind.Deferred.Or_error participant =
    Rpc.Rpc.dispatch_exn Rpc_protocol.login_rpc conn participant_name
  in
  let%bind result =
    Rpc.Pipe_rpc.dispatch Rpc_protocol.session_feed_rpc conn ()
  in
  let%bind () =
    match result with
    | Error err | Ok (Error err) ->
      print_endline [%string "ERROR subscribing: %{Error.to_string_hum err}"];
      return ()
    | Ok (Ok (reader, _id)) ->
      don't_wait_for
        (Pipe.iter_without_pushback reader ~f:(fun event ->
           match event with
           | Exchange_event.Fill fill ->
             (match
                Fill.to_participant_view ~render_symbol fill participant
              with
              | Some msg -> print_endline msg
              | None -> print_endline (Fill.to_string ~render_symbol fill))
           | other ->
             print_endline (Event_format.format_event ~render_symbol other)));
      return ()
  in
  print_endline
    [%string
      {|
Connected to exchange at %{host}:%{port#Int} as %{participant#Participant}
Commands: BUY|SELL <client_id> <symbol> <size> <price> [%{Time_in_force.all_str}]
          CANCEL <client_id>
          BOOK <symbol>
          SUBSCRIBE <symbol>  (stream market data)

Your order acknowledgements, fills, and cancellations stream in below;
the SUBSCRIBE command additionally attaches you to a per-symbol
market-data feed.|}];
  let rec loop () =
    print_string "> ";
    match%bind Reader.read_line (Lazy.force Reader.stdin) with
    | `Eof ->
      print_endline "\nDisconnected.";
      Deferred.Or_error.ok_unit
    | `Ok line ->
      let line = String.strip line in
      if String.is_empty line
      then loop ()
      else (
        match
          Exchange_command.parse
            line
            ~default_participant:participant
            ~directory
        with
        | Error err ->
          print_endline [%string "ERROR: %{Error.to_string_hum err}"];
          loop ()
        | Ok (Submit request) ->
          let%bind.Deferred.Or_error () =
            Rpc.Rpc.dispatch_exn Rpc_protocol.submit_order_rpc conn request
          in
          loop ()
        | Ok (Cancel client_order_id) ->
          let%bind.Deferred.Or_error () =
            Rpc.Rpc.dispatch_exn
              Rpc_protocol.cancel_order_rpc
              conn
              client_order_id
          in
          loop ()
        | Ok Stats ->
          let%bind stats =
            Rpc.Rpc.dispatch_exn Rpc_protocol.exchange_stats_rpc conn ()
          in
          print_s [%sexp (stats : Exchange_stats.t)];
          loop ()
        | Ok (Book symbol) ->
          let%bind result =
            Rpc.Rpc.dispatch_exn Rpc_protocol.book_query_rpc conn symbol
          in
          (match result with
           | None ->
             print_endline
               [%string "No book available for %{render_symbol symbol}"]
           | Some result ->
             print_endline (Book.to_string ~render_symbol result));
          loop ()
        | Ok (Subscribe symbol) ->
          let%bind result =
            Rpc.Pipe_rpc.dispatch
              Rpc_protocol.market_data_rpc
              conn
              [ symbol ]
          in
          (match result with
           | Error err | Ok (Error err) ->
             print_endline
               [%string "ERROR subscribing: %{Error.to_string_hum err}"];
             loop ()
           | Ok (Ok (reader, _id)) ->
             print_endline
               [%string
                 {|
Subscribed to %{render_symbol symbol} market data. Updates will appear below.
Continue entering commands as normal.|}];
             don't_wait_for
               (Pipe.iter_without_pushback reader ~f:(fun event ->
                  print_endline
                    [%string
                      "[MD] %{Event_format.format_event ~render_symbol \
                       event}"]));
             loop ()))
  in
  loop ()
;;

let () =
  Command.async_or_error
    ~summary:"JSIP Exchange client"
    (let%map_open.Command host =
       flag
         "-host"
         (optional_with_default "localhost" string)
         ~doc:"HOST server hostname"
     and port = flag "-port" (required int) ~doc:"PORT server port"
     and participant_name =
       flag
         "-name"
         (optional_with_default (Core_unix.getlogin ()) string)
         ~doc:"NAME participant name"
     in
     fun () -> run_client ~host ~port ~participant_name)
  |> Command_unix.run
;;
