(** Wire protocol between the dashboard's browser client and its web server.

    The dashboard server polls the exchange's
    [Jsip_gateway.Rpc_protocol.exchange_stats_rpc] once per second, buffers
    the {!Jsip_types.Exchange_stats.t} snapshots, and re-serves them to the
    browser through {!recent_samples_rpc} here. Raw snapshots travel
    unchanged — rates are derived from the cumulative counters by the
    browser's pure controller, where tests can reach them.

    This is a *polling* protocol, not a server push: the browser calls
    {!recent_samples_rpc} on a timer, passing the [taken_at] of the newest
    sample it already holds, and the server replies with everything newer.
    Polling is deliberate — a backgrounded browser tab simply stops asking,
    whereas a server-pushed stream would pile up unread diffs and stall on
    refocus. Because the query carries a high-water mark, the client never
    misses or double-counts a sample across polls or reconnects.

    Kept free of [Async] (uses only [async_rpc_kernel]) so the js_of_ocaml
    client can link it. *)

open! Core
open Jsip_types
module Rpc = Async_rpc_kernel.Rpc

module Recent_samples : sig
  module Query : sig
    (** [since] is the [taken_at] of the newest sample the client already
        has, or [None] on the first poll (send everything you have). *)
    type t = { since : Time_ns.t option } [@@deriving sexp, bin_io, equal]
  end

  module Response : sig
    type t =
      { samples : Exchange_stats.t list
      (** Buffered snapshots with [taken_at] strictly newer than the query's
          [since], oldest first. Bounded by the server's ring buffer. *)
      ; exchange_connected : bool
      (** Whether the dashboard server's poll of the exchange is currently
          succeeding. [false] means the samples are the tail of history from
          before the exchange went away — the UI must say so rather than
          render stale data as live (the v1 silent-freeze bug). *)
      }
    [@@deriving sexp_of, bin_io]
  end
end

(** Fetch samples newer than the client's high-water mark. *)
val recent_samples_rpc
  : (Recent_samples.Query.t, Recent_samples.Response.t) Rpc.Rpc.t
