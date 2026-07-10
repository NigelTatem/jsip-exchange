(** Central event-routing component for the gateway.

    Owns subscription registries:

    - **Market-data subscribers**, keyed by [Symbol_id.t]. Each subscriber
      gets a pipe of [Best_bid_offer_update] and [Trade_report] events for
      the symbol they asked about. This is the public market-data feed.

    - **Audit subscribers**, an unfiltered firehose of every event the
      matching engine produces. Intended for the exchange operator's monitor;
      not appropriate to expose to ordinary clients.

    [dispatch] is the single place that decides "for each event, who gets
    it".

    Subscriber pipes are bounded: a pipe that reaches the
    [subscriber_pipe_budget] given to {!create} is closed instead of written
    to — the subscriber is evicted, its resources are reclaimed by the usual
    closed-pipe cleanup, and the eviction is counted in {!evictions}. The
    dispatcher never blocks on a slow subscriber; a consumer that cannot keep
    up loses its feed rather than growing the exchange's memory. (Up to
    roughly one RPC batch of already-drained events can still sit in a
    connection's transport writer — that residual is observable per
    connection via {!Exchange_stats.Connection.bytes_to_write}.) *)

open! Core
open! Async
open Jsip_types

type t

(** Create a dispatcher. [subscriber_pipe_budget] is the maximum number of
    unread events any single subscriber pipe (market data, audit, or session)
    may hold; a pipe at the budget is closed on the next write — see the
    module comment for the eviction contract. [registry] is the server's
    shared participant name<->id map: session events name participants, and
    are routed to their session by the interned id. *)
val create
  :  subscriber_pipe_budget:int
  -> registry:Participant_registry.t
  -> unit
  -> t

val sessions : t -> Session.t Participant_id.Table.t

(** Subscribe to public market data for one or more [symbols]. The same pipe
    receives events for every requested symbol; the dispatcher avoids
    duplicates so a subscriber listed against multiple symbols only sees each
    event once. The pipe is removed from the dispatcher when its reader is
    closed.

    [label] identifies the subscriber in {!subscriber_stats} rows; embed the
    caller's identity (e.g. ["market-data:127.0.0.1:54321"]). *)
val subscribe_market_data
  :  t
  -> Symbol_id.t list
  -> label:string
  -> Exchange_event.t Pipe.Reader.t

(** Subscribe to the full unfiltered event firehose. Intended for the monitor
    / admin tools. [label] as in {!subscribe_market_data}. *)
val subscribe_audit : t -> label:string -> Exchange_event.t Pipe.Reader.t

(** Route each event to every interested subscriber:

    - Every event is pushed to every audit subscriber.
    - [Best_bid_offer_update] and [Trade_report] are pushed to the
      market-data subscribers that asked for the event's symbol.
    - [Order_accept], [Order_cancel], and [Order_reject] are pushed to the
      session of the order's owning participant (if logged in).
    - [Fill] is pushed to both the aggressor's and the resting party's
      session (if either is logged in).

    Each session lookup is O(1) and independent of subscriber count. *)
val dispatch : t -> Exchange_event.t list -> unit

(** One {!Exchange_stats.Subscriber} row per registered feed pipe:
    market-data subscribers (one row each, however many symbols they watch),
    audit subscribers, and logged-in session feeds (labeled
    ["session:<participant>"]). Read-only; O(subscribers + sessions). *)
val subscriber_stats : t -> Exchange_stats.Subscriber.t list

(** Events routed through {!dispatch} since {!create} (cumulative). *)
val events_dispatched : t -> int

(** Subscribers evicted for hitting the pipe budget since {!create}
    (cumulative). *)
val evictions : t -> int

val clean_up_session : t -> Session.t -> unit Deferred.t
val set_up_session : t -> Participant_id.t -> Session.t Deferred.t

module For_testing : sig
  val audit_subscriber_count : t -> int
end
