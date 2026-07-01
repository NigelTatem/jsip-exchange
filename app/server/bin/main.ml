(** Exchange server. Runs the matching engine and listens for RPC connections
    from clients.

    Run with: dune exec app/server/bin/main.exe -- -port 12345 *)
open! Core

open! Async
open Jsip_types
open Jsip_gateway

let default_symbols =
  [ Symbol.of_string "AAPL"
  ; Symbol.of_string "TSLA"
  ; Symbol.of_string "GOOG"
  ; Symbol.of_string "MSFT"
  ]
;;

let start ~port =
  let%bind server =
    Exchange_server.start ~symbols:default_symbols ~port ()
  in
  print_endline
    [%string
      "JSIP Exchange server listening on port %{Exchange_server.port \
       server#Int}"];
  let symbols =
    List.map default_symbols ~f:Symbol.to_string |> String.concat ~sep:", "
  in
  print_endline [%string "Trading: %{symbols}"];
  Exchange_server.close_finished server
;;

let () =
  Command.async
    ~summary:"JSIP Exchange server"
    (let%map_open.Command port =
       flag "-port" (required int) ~doc:"PORT port to listen on"
     in
     fun () -> start ~port)
  |> Command_unix.run
;;
