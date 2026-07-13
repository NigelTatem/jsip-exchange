open! Core
open Jsip_types

module Action = struct
  type t =
    | Submit of Order.Request.t
    | Cancel of
        { participant : Participant.t
        ; client_order_id : Client_order_id.t
        }
  [@@deriving sexp_of]
end

module Config = struct
  type t =
    { num_symbols : int
    ; num_participants : int
    ; cancel_fraction : float
    ; marketable_fraction : float
    ; ioc_fraction : float
    ; min_size : int
    ; max_size : int
    ; base_price_cents : int
    ; resting_offset_cents : int
    ; target_depth : int
    (** Ceiling on outstanding cancelable orders. Because every resting order
        the generator submits is enqueued as a cancel candidate, capping that
        queue at [target_depth] bounds the live book depth — this is the
        negative feedback that lets even a submit-heavy preset reach a stable
        (rather than forever-growing) steady state. *)
    }
  [@@deriving sexp_of]

  (* Roughly equal submits and cancels with a mix of resting and marketable
     flow: the book fills and plateaus at a meaningful middle-ground depth
     (~6000, between [churn]'s ~1800 and [book-heavy]'s ~47500), while ~47%
     of accepts still cross into fills. Like the other presets this is
     cap-driven: resting inflow ~ (1-cancel)*(1-marketable)*(1-ioc) must beat
     crossing outflow ~ (1-cancel)*marketable so the cancel queue saturates
     at [target_depth]; live book depth settles at ~0.75x the cap, the rest
     of the queue being stale entries that cancel-reject on pop. The original
     [marketable_fraction = 0.5] lost that race, draining the book to ~0. *)
  let balanced =
    { num_symbols = 16
    ; num_participants = 8
    ; cancel_fraction = 0.30
    ; marketable_fraction = 0.25
    ; ioc_fraction = 0.2
    ; min_size = 1
    ; max_size = 500
    ; base_price_cents = 15_000
    ; resting_offset_cents = 10
    ; target_depth = 8_000
    }
  ;;

  (* High add/remove turnover on a modest standing book. Inflow must exceed
     outflow so the book saturates at [target_depth] rather than draining;
     once there, the cap enforces ~50/50 submit/cancel, so [remove] runs
     constantly against a live (non-empty) book. Note a literally
     cancel-dominated (>50%) flow can't hold a book — at steady state cancels
     match resting submits — so "churn" here means turnover, not net removal. *)
  let churn =
    { balanced with
      cancel_fraction = 0.25
    ; marketable_fraction = 0.1
    ; ioc_fraction = 0.1
    ; target_depth = 2_000
    }
  ;;

  (* Resting-order pileup: submits dominate, almost nothing crosses, so the
     book fills up to a deep [target_depth] and holds there. The cap is what
     keeps it a steady state rather than unbounded growth. *)
  let book_heavy =
    { balanced with
      cancel_fraction = 0.05
    ; marketable_fraction = 0.05
    ; ioc_fraction = 0.0
    ; target_depth = 50_000
    }
  ;;

  let of_preset_name = function
    | "balanced" -> Some balanced
    | "churn" -> Some churn
    | "book-heavy" -> Some book_heavy
    | _ -> None
  ;;
end

type t =
  { config : Config.t
  ; rng : Splittable_random.t
  ; symbols : Symbol_id.t array
  ; participants : Participant.t array
  ; (* A fresh, never-reused client order id per action. The engine keys
       duplicate detection on [(participant, client_order_id)] and never
       forgets a used id, so this only ever increases. *)
    mutable next_client_id : int
  ; (* Outstanding resting orders we submitted and could later cancel. We pop
       from the front to cancel the oldest, which keeps the book from growing
       without bound. Entries may be stale (already filled) — a cancel of a
       non-resting order just produces a [Cancel_reject], which the driver
       counts and moves on. *)
    cancel_candidates : (Participant.t * Client_order_id.t) Queue.t
  }

let create (config : Config.t) ~seed =
  let symbols =
    Array.init config.num_symbols ~f:(fun i -> Symbol_id.of_int i)
  in
  let participants =
    Array.init config.num_participants ~f:(fun i ->
      Participant.of_string [%string "P%{i#Int}"])
  in
  { config
  ; rng = Splittable_random.of_int seed
  ; symbols
  ; participants
  ; next_client_id = 0
  ; cancel_candidates = Queue.create ()
  }
;;

let fresh_client_id t =
  let id = t.next_client_id in
  t.next_client_id <- id + 1;
  Client_order_id.of_int id
;;

let pick t array =
  array.(Splittable_random.int t.rng ~lo:0 ~hi:(Array.length array - 1))
;;

let coin t ~probability =
  Float.( < ) (Splittable_random.float t.rng ~lo:0. ~hi:1.) probability
;;

(* Price a submit so the two sides keep crossing around a fixed mid. A buy
   wants a higher price to cross and a sell a lower one; being marketable
   flips which side of the mid the order sits on. Resting orders sit
   [resting_offset_cents] behind the mid (bids below, asks above), so a
   marketable buy lands on the resting asks and a marketable sell on the
   resting bids. The offset is equal-and-opposite about the mid, so the BBO
   stays put and prices never run away. *)
let choose_price t ~ref_cents ~(side : Side.t) ~(marketable : bool) : Price.t
  =
  let above_mid =
    match side with Buy -> marketable | Sell -> not marketable
  in
  let cents =
    if above_mid
    then ref_cents + t.config.resting_offset_cents
    else ref_cents - t.config.resting_offset_cents
  in
  Price.of_int_cents cents
;;

let generate_submit t : Action.t =
  let config = t.config in
  let symbol_ix =
    Splittable_random.int t.rng ~lo:0 ~hi:(config.num_symbols - 1)
  in
  let symbol = t.symbols.(symbol_ix) in
  let participant = pick t t.participants in
  let side : Side.t = if coin t ~probability:0.5 then Buy else Sell in
  let marketable = coin t ~probability:config.marketable_fraction in
  let time_in_force : Time_in_force.t =
    if coin t ~probability:config.ioc_fraction then Ioc else Day
  in
  let size =
    Size.of_int
      (Splittable_random.int t.rng ~lo:config.min_size ~hi:config.max_size)
  in
  let price =
    choose_price t ~ref_cents:config.base_price_cents ~side ~marketable
  in
  let client_order_id = fresh_client_id t in
  (* Every order that can rest becomes a cancel candidate — including
     marketable Day orders, which rest if they don't fully cross. Enqueuing
     all of them means the queue length is an upper bound on live resting
     orders, which is what makes the [target_depth] cap in [next] bound the
     book. A candidate that already filled just yields a harmless
     [Cancel_reject] when popped. *)
  if Time_in_force.rests_on_book time_in_force
  then Queue.enqueue t.cancel_candidates (participant, client_order_id);
  Submit
    { symbol
    ; participant
    ; side
    ; price
    ; size
    ; time_in_force
    ; client_order_id
    }
;;

let next t : Action.t =
  let queued = Queue.length t.cancel_candidates in
  (* Cancel when we randomly choose to, OR when we're holding at least
     [target_depth] cancelable orders — the latter is the hard ceiling that
     forces the book back down and guarantees a bounded steady state. *)
  let want_cancel =
    queued > 0
    && (queued >= t.config.target_depth
        || coin t ~probability:t.config.cancel_fraction)
  in
  if want_cancel
  then (
    let participant, client_order_id =
      Queue.dequeue_exn t.cancel_candidates
    in
    Cancel { participant; client_order_id })
  else generate_submit t
;;
