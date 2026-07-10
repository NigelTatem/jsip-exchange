(** Per-participant, per-symbol profit-and-loss tracking.

    A {!t} accumulates trading state for every participant the exchange has
    seen. For each [(participant, symbol)] pair it tracks three things:

    - {b inventory}: the signed position in shares (positive = long, negative
      = short);
    - {b cost basis}: the total signed cost of the current position, from
      which an {e average entry price} is derived ([cost_basis / shares]);
    - {b realized cash}: profit or loss locked in when shares are closed out.

    From these it reports two flavors of P&L:

    - {b realized}: cash from closed positions. Selling shares above their
      average entry price (or buying back a short below it) books a gain.
    - {b unrealized}: mark-to-market on the open position,
      [shares * (reference_price - average_entry_price)]. This requires a
      {e reference price}, refreshed from public trade prints via
      {!apply_trade_report}.

    This module is a pure fold over the event stream: feed it {!Fill.t}s
    (from the private participant feed) and {!Trade_report.t}s (from the
    public market-data feed) and read back a {!Summary.t}. It fits alongside
    {!Jsip_types.Exchange_event} — a monitor or bot can route [Fill] events
    to {!apply_fill} and [Trade_report] events (via
    {!Trade_report.of_exchange_event}) to {!apply_trade_report}.

    Because a {!Fill.t} names both an aggressor and a resting participant,
    {!apply_fill} updates {b both} sides of the trade — the aggressor on its
    own side, the resting participant on the flipped side. *)

open! Core
open Jsip_types

type t

(** A tracker with no participants and no positions. *)
val empty : t

(** Apply a private fill, updating both the aggressor's and the resting
    participant's positions for the fill's symbol. Prices are taken from the
    fill; no reference price is changed. *)
val apply_fill : t -> Fill.t -> t

(** A public trade print: the last price at which [symbol] traded. This is
    the market-data projection of {!Jsip_types.Exchange_event.Trade_report} —
    it carries no participant information, only what the whole market sees. *)
module Trade_report : sig
  type t =
    { symbol : Symbol_id.t
    ; price : Price.t
    }
  [@@deriving sexp_of]

  (** Extract the trade print from an exchange event, or [None] if the event
      is not a [Trade_report]. *)
  val of_exchange_event : Exchange_event.t -> t option
end

(** Refresh the reference price used for unrealized P&L on every open
    position in the report's symbol, across all participants. Positions in
    other symbols are untouched. *)
val apply_trade_report : t -> Trade_report.t -> t

(** A point-in-time P&L readout for a single participant. *)
module Summary : sig
  (** One symbol's line in a participant's summary. All cash figures are in
      integer cents, matching {!Jsip_types.Price}. *)
  type per_symbol =
    { symbol : Symbol_id.t
    ; position : int (** Signed shares: positive long, negative short. *)
    ; average_entry_price : Price.t option
    (** Average price paid for the open position, or [None] when flat.
        Rounded to the nearest cent for display; unrealized P&L is computed
        from the exact cost basis, not this rounded value. *)
    ; reference_price : Price.t option
    (** Last trade print seen for the symbol, or [None] if none yet. *)
    ; realized_cents : int
    ; unrealized_cents : int
    }
  [@@deriving sexp_of]

  type t =
    { per_symbol : per_symbol list
    ; total_realized_cents : int
    ; total_unrealized_cents : int
    }
  [@@deriving sexp_of]
end

(** The participant's per-symbol breakdown plus totals. Symbols the
    participant has never traded are absent from [per_symbol]. *)
val summary : t -> Participant.t -> Summary.t
