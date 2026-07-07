open! Core
open! Bonsai_web
open Bonsai.Let_syntax
module Protocol = Jsip_dashboard_protocol
module Controller = Jsip_dashboard_controller.Controller
module Query = Protocol.Recent_samples.Query

(* The dashboard polls its server once per second for samples newer than the
   ones it already holds. Polling (rather than a server-pushed pipe) means a
   backgrounded tab simply stops asking instead of accumulating unread diffs.
   Poll failures are fed to the controller too, so the UI can say "dashboard
   unreachable" instead of silently freezing. *)
let poll_every = Time_ns.Span.of_sec 1.0

module Action = struct
  type t =
    | Feed of Protocol.Recent_samples.Response.t
    | Poll_error
end

let app (local_ graph) : Vdom.Node.t Bonsai.t =
  let controller, inject =
    Bonsai.state_machine
      ~default_model:(Controller.create ())
      ~apply_action:(fun _ctx model action ->
        match (action : Action.t) with
        | Feed response -> Controller.feed_response model response
        | Poll_error -> Controller.feed_poll_error model)
      graph
  in
  (* The poll query carries our high-water mark, so the server only ever
     sends genuinely new samples and we never double-count across polls. *)
  let query =
    let%arr controller in
    { Query.since = Controller.last_seen_at controller }
  in
  let on_response_received =
    let%arr inject in
    fun (_ : Query.t)
      (response : Protocol.Recent_samples.Response.t Or_error.t) ->
      match response with
      | Ok response -> inject (Action.Feed response)
      | Error (_ : Error.t) -> inject Action.Poll_error
  in
  let (_ : Protocol.Recent_samples.Response.t option Bonsai.t) =
    Rpc_effect.Rpc.poll
      Protocol.recent_samples_rpc
      ~equal_query:[%equal: Query.t]
      ~on_response_received
      ~every:(Bonsai.return poll_every)
      ~output_type:Rpc_effect.Poll_result.Output_type.Last_ok_response
      query
      graph
  in
  (* Staleness only needs ~1s resolution; approx_now avoids re-rendering
     every frame the way Clock.Expert.now would. *)
  let now = Bonsai.Clock.approx_now ~tick_every:poll_every graph in
  let%arr controller and now in
  Panes.page (Controller.display controller ~now)
;;
