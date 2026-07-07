open! Core
open! Async
open Jsip_types
module Ws = Rpc_websocket.Rpc
module Protocol = Jsip_dashboard_protocol
module Rpc_protocol = Jsip_gateway.Rpc_protocol

(* The dashboard server is a small bridge: it polls a running exchange's
   [exchange_stats_rpc] once per second as an ordinary RPC client and buffers
   the snapshots. It serves two things to the browser on one HTTP port: the
   static client bundle, and [Protocol.recent_samples_rpc] over a websocket
   (a browser can't speak raw Async-RPC-over-TCP, so the websocket bridge is
   unavoidable).

   The poll loop owns reconnection: if the exchange is down or restarts, the
   server keeps its buffered history, reports [exchange_connected = false] on
   the wire, and retries every poll interval. The dashboard never silently
   freezes — the browser is told the data is stale (the v1 failure this
   design removes). *)

let poll_every = Time_ns.Span.of_sec 1.0

(* Hold two of the client's ~120-sample windows so a client that reconnects
   can immediately backfill everything it can display. *)
let sample_buffer_size = 240

module Buffer = struct
  type t = { mutable samples : Exchange_stats.t list } (* oldest -> newest *)

  let create () = { samples = [] }

  let add t (sample : Exchange_stats.t) =
    let samples = t.samples @ [ sample ] in
    let overflow = List.length samples - sample_buffer_size in
    t.samples
    <- (if overflow > 0 then List.drop samples overflow else samples)
  ;;

  let since t = function
    | None -> t.samples
    | Some cutoff ->
      List.filter t.samples ~f:(fun (sample : Exchange_stats.t) ->
        Time_ns.( > ) sample.taken_at cutoff)
  ;;
end

module Exchange_link = struct
  (* What the wire reports to the browser: is the poll currently succeeding?
     [set] logs transitions so the operator's terminal tells the same story
     as the UI. *)
  type t = { mutable connected : bool }

  let create () = { connected = false }

  let set t connected =
    (match t.connected, connected with
     | false, true -> print_endline "[dashboard] exchange connected"
     | true, false ->
       print_endline "[dashboard] exchange unreachable; retrying"
     | true, true | false, false -> ());
    t.connected <- connected
  ;;
end

let rec poll_forever ~buffer ~link ~host ~port =
  let where = Tcp.Where_to_connect.of_host_and_port { host; port } in
  match%bind Rpc.Connection.client where with
  | Error (_ : Exn.t) ->
    Exchange_link.set link false;
    let%bind () = Clock_ns.after poll_every in
    poll_forever ~buffer ~link ~host ~port
  | Ok connection ->
    let rec poll_once () =
      match%bind
        Rpc.Rpc.dispatch Rpc_protocol.exchange_stats_rpc connection ()
      with
      | Ok sample ->
        Exchange_link.set link true;
        Buffer.add buffer sample;
        let%bind () = Clock_ns.after poll_every in
        poll_once ()
      | Error (_ : Error.t) ->
        Exchange_link.set link false;
        let%bind () = Rpc.Connection.close connection in
        let%bind () = Clock_ns.after poll_every in
        poll_forever ~buffer ~link ~host ~port
    in
    poll_once ()
;;

let implementations ~buffer ~link =
  Rpc.Implementations.create_exn
    ~implementations:
      [ Rpc.Rpc.implement
          Protocol.recent_samples_rpc
          (fun () (query : Protocol.Recent_samples.Query.t) ->
             return
               { Protocol.Recent_samples.Response.samples =
                   Buffer.since buffer query.since
               ; exchange_connected = link.Exchange_link.connected
               })
      ]
    ~on_unknown_rpc:`Close_connection
    ~on_exception:Log_on_background_exn
;;

let index_html =
  {html|<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>JSIP Exchange · Operations</title>
<style>
:root {
  color-scheme: dark;
  --font-sans: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  --font-mono: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  --font-weight-normal: 400; --font-weight-medium: 500; --font-weight-semibold: 600;
  --font-size-xs: 12px; --font-size-sm: 13px; --font-size-md: 15px; --font-size-lg: 22px;
  --space-xs: 4px; --space-sm: 8px; --space-md: 12px; --space-lg: 16px; --space-xl: 24px; --space-2xl: 32px;
  --radius-sm: 4px; --radius-md: 6px; --radius-lg: 8px;
  --color-bg-0: lch(3% 1 260);
  --color-bg-1: lch(12% 1.5 280);
  --color-bg-2: lch(15% 1.5 280);
  --color-text-primary: lch(97.5% 0.5 240);
  --color-text-secondary: lch(86% 4 250);
  --color-text-tertiary: lch(61% 4 260);
  --color-text-quaternary: lch(44% 3 260);
  --color-border-1: lch(16% 2 260);
  --color-accent: lch(62% 50 275);
  --color-ok: lch(70% 45 150);
  --color-warn: lch(72% 55 75);
  --color-bad: lch(58% 55 25);
  --shadow-1: 0.5px 1px 1px lch(0% 0 0 / 0.35);
}
* { box-sizing: border-box; scrollbar-width: thin; }
html, body { margin: 0; height: 100%; }
body {
  background: var(--color-bg-0); color: var(--color-text-primary);
  font-family: var(--font-sans); font-variant-numeric: tabular-nums;
  -webkit-font-smoothing: antialiased;
}
#app { height: 100%; }
.loading { padding: var(--space-2xl); color: var(--color-text-tertiary); }
</style>
</head>
<body>
<div id="app"><div class="loading">Loading dashboard…</div></div>
<script defer src="/main.bc.js"></script>
</body>
</html>
|html}
;;

let respond ~content_type body =
  let headers = Cohttp.Header.init_with "content-type" content_type in
  Cohttp_async.Server.respond_string ~headers body
;;

let http_handler ~js_bundle ~body:_ (_ : Socket.Address.Inet.t) request =
  match Uri.path (Cohttp.Request.uri request) with
  | "/" | "/index.html" ->
    respond ~content_type:"text/html; charset=utf-8" index_html
  | "/main.bc.js" -> respond ~content_type:"text/javascript" js_bundle
  | _ -> Cohttp_async.Server.respond_string ~status:`Not_found "not found"
;;

let serve ~http_port ~js_bundle ~buffer ~link =
  Ws.serve
    ~where_to_listen:(Tcp.Where_to_listen.of_port http_port)
    ~implementations:(implementations ~buffer ~link)
    ~initial_connection_state:(fun () _from _addr _conn -> ())
    ~http_handler:(fun () -> http_handler ~js_bundle)
    ()
;;

let main ~http_port ~exchange_host ~exchange_port ~js_path () =
  let%bind js_bundle = Reader.file_contents js_path in
  let buffer = Buffer.create () in
  let link = Exchange_link.create () in
  don't_wait_for
    (poll_forever ~buffer ~link ~host:exchange_host ~port:exchange_port);
  let%bind (_ : (_, _) Cohttp_async.Server.t) =
    serve ~http_port ~js_bundle ~buffer ~link
  in
  printf
    "JSIP dashboard on http://localhost:%d (exchange %s:%d)\n%!"
    http_port
    exchange_host
    exchange_port;
  Deferred.never ()
;;

let command =
  Command.async
    ~summary:
      "Web dashboard for a JSIP exchange: polls the exchange's stats RPC \
       and serves them to a browser."
    (let%map_open.Command http_port =
       flag
         "-port"
         (optional_with_default 8080 int)
         ~doc:"PORT HTTP port to serve the dashboard on (default 8080)"
     and exchange_host =
       flag
         "-exchange-host"
         (optional_with_default "localhost" string)
         ~doc:"HOST exchange server host (default localhost)"
     and exchange_port =
       flag "-exchange-port" (required int) ~doc:"PORT exchange server port"
     and js_path =
       flag
         "-js"
         (optional_with_default
            "_build/default/app/dashboard/client/main.bc.js"
            string)
         ~doc:"PATH compiled client bundle (default: the dune build output)"
     in
     fun () -> main ~http_port ~exchange_host ~exchange_port ~js_path ())
    ~behave_nicely_in_pipeline:false
;;

let () = Command_unix.run command
