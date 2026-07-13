(** A synthetic order-flow generator for driving the matching engine under
    load (Part 4, Exercise 6).

    Unlike the Part 2 scenarios — which are throttled, tick-driven, and
    mostly idle — this generator produces a dense, back-to-back stream of
    {!Action.t}s (submits and cancels) with no waiting. It is meant to be
    pumped straight into {!Jsip_order_book.Matching_engine} by the [replay]
    driver so a profiler sees the engine working flat out, not sleeping.

    Every "random" choice is drawn from a single {!Splittable_random.State.t}
    seeded once, so the same seed always yields the same action stream. That
    determinism is what makes before/after comparisons valid.

    The generator holds no reference to the engine and gets no feedback from
    it: it just emits actions. Keeping it decoupled keeps its own allocation
    (which would otherwise pollute the profile) minimal and obvious. *)

open! Core
open Jsip_types

(** One unit of order flow. The [replay] driver turns a [Submit] into
    {!Jsip_order_book.Matching_engine.submit} and a [Cancel] into
    {!Jsip_order_book.Matching_engine.cancel}. *)
module Action : sig
  type t =
    | Submit of Order.Request.t
    | Cancel of
        { participant : Participant.t
        ; client_order_id : Client_order_id.t
        }
  [@@deriving sexp_of]
end

(** Knobs controlling the {e shape} of the traffic. A config is a fixed
    description of a workload; the per-run randomness lives in the generator
    state, not here. *)
module Config : sig
  type t =
    { num_symbols : int (** how many distinct symbols the stream spans *)
    ; num_participants : int (** how many distinct participants *)
    ; cancel_fraction : float
    (** probability an action is a cancel (of an outstanding resting order)
        rather than a submit, in [0., 1.] *)
    ; marketable_fraction : float
    (** probability a submit is priced to cross (take liquidity) rather than
        rest, in [0., 1.] *)
    ; ioc_fraction : float
    (** probability a submit is [Ioc] rather than [Day], in [0., 1.] *)
    ; min_size : int (** smallest order size (inclusive) *)
    ; max_size : int (** largest order size (inclusive) *)
    ; base_price_cents : int
    (** the reference ("mid") price every symbol trades around, in cents.
        Fixed for the whole run — the market does not drift, which is the
        simplest way to keep the two sides crossing (see Exercise 6's "prices
        must not run away"). *)
    ; resting_offset_cents : int
    (** how far behind the mid a resting order is placed, in cents *)
    ; target_depth : int
    (** ceiling on outstanding cancelable orders, which bounds the live book
        depth. This is the negative feedback that lets a submit-heavy preset
        reach a stable steady state instead of a forever-growing book: once
        the generator is holding [target_depth] cancelable orders, every
        further action is a cancel until it drops back below. *)
    }
  [@@deriving sexp_of]

  (** Roughly equal submits and cancels, a mix of resting and marketable
      flow: the book fills and then plateaus. *)
  val balanced : t

  (** Cancel-heavy flow: stresses the add/remove churn path. *)
  val churn : t

  (** Resting-order pileup: submits dominate and few cross, so the book grows
      deep. *)
  val book_heavy : t

  (** Look up a preset by name (["balanced"], ["churn"], ["book-heavy"]). *)
  val of_preset_name : string -> t option
end

type t

(** [create config ~seed] builds a generator. All randomness derives from
    [seed], so two generators with the same config and seed emit identical
    action streams. *)
val create : Config.t -> seed:int -> t

(** Produce the next action, advancing the generator's internal RNG and
    bookkeeping. Never blocks and never repeats a client order id. *)
val next : t -> Action.t
