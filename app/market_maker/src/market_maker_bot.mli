open! Core
open! Async
open Jsip_types
module Bot_runtime = Jsip_bot_runtime.Bot_runtime

module Config : sig
  type t =
    { symbol : Symbol.t
    ; half_spread_cents : int
    ; size_per_level : int
    ; num_levels : int
    ; inventory_skew_cents_per_share : int
    ; state_id : string
    }
  [@@deriving sexp_of]
end

val name : string
val on_start : Config.t -> Bot_runtime.Context.t -> unit Deferred.t
val on_tick : Config.t -> Bot_runtime.Context.t -> unit Deferred.t

val on_event
  :  Config.t
  -> Bot_runtime.Context.t
  -> Exchange_event.t
  -> unit Deferred.t

val create_config
  :  symbol:Symbol.t
  -> half_spread_cents:int
  -> size_per_level:int
  -> num_levels:int
  -> inventory_skew_cents_per_share:int
  -> Config.t
