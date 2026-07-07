(** The dashboard's pure state machine.

    No Bonsai, no Async, no js_of_ocaml: [feed_*] advances the state,
    {!display} projects it into plain data for rendering. This mirrors
    [app/monitor/src/controller.ml] and keeps everything interesting
    reachable from [dune runtest] — including the rate computation, the one
    genuinely subtle piece (cumulative counters can go *backward* across an
    exchange restart, and that must render as a gap, not a negative rate).

    The state is a rolling window of the last {!window_size} snapshots (~2
    minutes at the 1 s poll cadence): long enough that a stall spike or a
    slow climb is still on screen after it ends, small enough to render one
    bar per sample. *)

open! Core
open Jsip_types

module Display : sig
  (** Render-ready projection: strings, numbers, and already-sorted rows.
      Panes render this and nothing else — they never see raw samples. *)

  module Connection_row : sig
    type t =
      { peer : string
      ; participant : string option (** [None] = never logged in. *)
      ; bytes_to_write : int
      }
    [@@deriving sexp_of, compare, equal]
  end

  module Participant_row : sig
    type t =
      { participant : Participant.t
      ; submits_per_sec : float option
      (** Averaged over the window; [None] when there is only one sample or
          the counter went backward (exchange restart). *)
      ; resting_orders : int
      }
    [@@deriving sexp_of, compare, equal]
  end

  module Symbol_row : sig
    type t =
      { symbol : Symbol.t
      ; bid : string (** e.g. ["$150.00 x60"] or ["—"]. *)
      ; ask : string
      ; bid_depth : int
      ; ask_depth : int
      }
    [@@deriving sexp_of, compare, equal]
  end

  type t =
    { sample_count : int
    ; staleness : Time_ns.Span.t option
    (** Age of the newest sample, or [None] before the first one. *)
    ; exchange_connected : bool
    (** Server-reported: is the dashboard server's exchange poll healthy? *)
    ; dashboard_reachable : bool
    (** Client-observed: did our last poll of the dashboard server succeed? *)
    ; connections : Connection_row.t list
    (** Sorted by [bytes_to_write] descending — worst first. *)
    ; participants : Participant_row.t list
    (** Sorted by [submits_per_sec] descending — busiest first. *)
    ; symbols : Symbol_row.t list
    ; events_per_sec_series : float option list
    (** Per-poll-interval dispatch rate, oldest first; [None] marks a counter
        reset (restart discontinuity). *)
    ; max_gap_ms_series : float list
    (** Engine max-gap per sample in milliseconds, oldest first. *)
    ; request_queue_series : int list
    ; evictions : int (** Cumulative, from the newest sample. *)
    }
  [@@deriving sexp_of, equal]
end

type t [@@deriving sexp_of, equal]

val window_size : int
val create : unit -> t

(** [taken_at] of the newest retained sample — the poll high-water mark to
    send as [Query.since]. *)
val last_seen_at : t -> Time_ns.t option

(** Append a poll response (samples oldest first), trim the window, and
    record the server-reported exchange health. Also marks the dashboard
    server itself as reachable again after {!feed_poll_error}. *)
val feed_response
  :  t
  -> Jsip_dashboard_protocol.Recent_samples.Response.t
  -> t

(** Record that a poll of the dashboard server failed. Samples are kept —
    they're real history — but {!Display.dashboard_reachable} goes false
    until the next successful poll. *)
val feed_poll_error : t -> t

(** Project for rendering. [now] is only used to compute staleness. *)
val display : t -> now:Time_ns.t -> Display.t
