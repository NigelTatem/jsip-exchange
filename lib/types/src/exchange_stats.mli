(** A point-in-time snapshot of exchange health.

    Covers the four metric families from the stats design
    ([doc/design-exchange-stats.md]):

    - {!Subscriber}: backlog of each feed pipe inside the the gateway's
      [Dispatcher] (layer 1 of the buffering picture)
    - {!Connection}: transport-writer backlog of each live RPC connection
      (layer 2 — where a slow network reader's bytes actually accumulate)
    - {!Participant_activity}: cumulative submit counts and live
      resting-order counts
    - {!Symbol_depth}: live BBO and total resting size per side
    - {!Engine}: matching-loop busyness

    Snapshots are assembled by the gateway's [Exchange_server.stats] and
    polled over RPC. Counters ([submits], [events_dispatched]) are
    cumulative: a poller computes rates from deltas between successive
    snapshots using [taken_at], so the server never has to pick an averaging
    window. *)

open! Core

module Subscriber : sig
  (** One row per feed pipe registered with the the gateway's [Dispatcher]:
      market-data and audit subscriptions plus logged-in session feeds. *)
  type t =
    { label : string
    (** Who this pipe belongs to, e.g. ["market-data:127.0.0.1:54321"] or
        ["session:Alice"]. Market-data and audit labels embed the subscribing
        connection's peer address so rows here can be lined up with
        {!Connection} rows. *)
    ; pipe_length : int
    (** Events sitting unread in the dispatcher-side pipe. Expect this to
        read near zero for RPC subscribers even when the client is slow:
        [Rpc.Pipe_rpc] eagerly drains the pipe into the transport writer, so
        the slow-reader signal lives in {!Connection.bytes_to_write}. *)
    }
  [@@deriving sexp_of, bin_io, compare, equal]
end

module Connection : sig
  (** One row per live RPC connection, whether or not it ever logged in. *)
  type t =
    { peer : string (** Remote address, e.g. ["127.0.0.1:54321"]. *)
    ; participant : Participant.t option
    (** [None] until the connection logs in. A large [bytes_to_write] with
        [participant = None] and no submit activity is the read-only-abuser
        signature. *)
    ; bytes_to_write : int
    (** Bytes buffered in the connection's transport writer, waiting for the
        peer's socket to drain ([Rpc.Connection.bytes_to_write]). *)
    }
  [@@deriving sexp_of, bin_io, compare, equal]
end

module Participant_activity : sig
  (** One row per participant that has submitted an order or currently has
      orders resting in a book. *)
  type t =
    { participant : Participant.t
    ; submits : int
    (** Orders submitted since the server started. Cumulative — never resets;
        rate = delta between snapshots over delta [taken_at]. *)
    ; resting_orders : int (** Orders resting in the books right now. *)
    }
  [@@deriving sexp_of, bin_io, compare, equal]
end

module Symbol_depth : sig
  (** One row per symbol the engine trades. *)
  type t =
    { symbol : Symbol.t
    ; bbo : Bbo.t (** Best bid/offer, with per-level sizes. *)
    ; bid_depth : Size.t (** Total resting size across all bid levels. *)
    ; ask_depth : Size.t (** Total resting size across all ask levels. *)
    }
  [@@deriving sexp_of, bin_io, compare, equal]
end

module Engine : sig
  (** Matching-loop busyness. *)
  type t =
    { max_gap_since_last_snapshot : Time_ns.Span.t
    (** Longest gap observed between successive matching-loop iterations
        since the previous snapshot. Near zero while the engine keeps up; a
        stall shows up here even if it ended long before the poller's next
        sample. Reading a snapshot resets it, so concurrent pollers steal
        each other's peaks. With sparse traffic this also picks up harmless
        inter-arrival gaps. *)
    ; request_queue_length : int
    (** Requests waiting for the matching loop. Bounded by the server's
        ingress budget, so a full queue means clients are being pushed back
        on. *)
    }
  [@@deriving sexp_of, bin_io, compare, equal]
end

type t =
  { taken_at : Time_ns.t (** When the snapshot was assembled. *)
  ; subscribers : Subscriber.t list
  ; connections : Connection.t list
  ; participants : Participant_activity.t list
  ; symbols : Symbol_depth.t list
  ; engine : Engine.t
  ; events_dispatched : int
  (** Events routed by the dispatcher since server start (cumulative). *)
  ; evictions : int
  (** Subscribers forcibly disconnected because their feed pipe hit the
      server's size budget (cumulative). Nonzero means a consumer fell so far
      behind that the exchange chose to protect its own memory. *)
  }
[@@deriving sexp_of, bin_io, compare, equal]
