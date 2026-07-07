open! Core
open! Async
open Jsip_types
module Context = Jsip_bot_runtime.Bot_runtime.Context

module Read_behavior = struct
  type t =
    | Never
    | Delay_per_event of Time_ns.Span.t
  [@@deriving sexp_of]
end

module Config = struct
  type t = { read_behavior : Read_behavior.t } [@@deriving sexp_of]

  let create ~read_behavior = { read_behavior }
end

let name = "slow-consumer"
let on_start (_config : Config.t) (_ctx : Context.t) = return ()

(* A slow consumer submits nothing. *)
let on_tick (_config : Config.t) (_ctx : Context.t) = return ()

(* The whole pathology lives here. The runtime drains this bot's feeds with
   [Pipe.iter pipe ~f:(feed_event bot)], and [Pipe.iter] will not pull the
   next element until the deferred returned by [f] -- ultimately this
   [on_event] -- is determined. So delaying (or never determining) here
   throttles how fast the bot reads its market-data pipe.

   Reading slower than events arrive backs a pipe up — but, measured against
   exchange stats (2026-07-07), it is the *bot-side* pipe that grows: the
   async-rpc client in this process keeps reading the socket and buffering
   events into the pipe this [on_event] refuses to drain, so the memory cost
   lands in the bot's own process. The exchange-side buffers stay near zero
   as long as the socket keeps draining ([Rpc.Pipe_rpc] empties the
   dispatcher pipe into the transport writer, which empties into the socket).
   Exchange memory is only at risk when the socket itself stops draining
   (e.g. a [kill -STOP]ped subscriber) — and the dispatcher now bounds
   subscriber pipes and evicts at the budget (see [Dispatcher]), so even that
   is capped. *)
let on_event
  (config : Config.t)
  (_ctx : Context.t)
  (_event : Exchange_event.t)
  =
  match config.read_behavior with
  | Never -> Deferred.never ()
  | Delay_per_event span -> Clock_ns.after span
;;
