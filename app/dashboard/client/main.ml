open! Core
open! Bonsai_web

(* js_of_ocaml entry point. The server serves the compiled bundle alongside
   an index.html that hosts this app and an RPC-over-websocket endpoint the
   poll connects back to (the default [where_to_connect] is "self"). *)
let () = Bonsai_web.Start.start ~bind_to_element_with_id:"app" App.app
