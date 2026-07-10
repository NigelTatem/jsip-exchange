open! Core
open Jsip_types

(* Internal per-[(participant, symbol)] accounting cell. [cost_basis_cents]
   is signed and kept equal to [average_entry_cents * shares], so it is
   positive for longs (cash paid) and negative for shorts (cash received).
   Storing the basis rather than an average price keeps the arithmetic exact
   — no rounding accumulates across many fills. *)
module Position = struct
  type t =
    { shares : int
    ; cost_basis_cents : int
    ; realized_cents : int
    ; reference_price : Price.t option
    }

  let empty =
    { shares = 0
    ; cost_basis_cents = 0
    ; realized_cents = 0
    ; reference_price = None
    }
  ;;

  (* Apply one execution (a fill from a single participant's point of view)
     to a position, booking realized P&L and updating the cost basis. *)
  let apply_execution t ~(side : Side.t) ~price ~size =
    let price_cents = Price.to_int_cents price in
    (* Signed change in shares: +size for a buy, -size for a sell. *)
    let delta = Side.sign side * Size.to_int size in
    if t.shares = 0 || Sign.equal (Int.sign delta) (Int.sign t.shares)
    then
      (* Opening a fresh position or adding to one in the same direction. No
         P&L is realized; we simply grow the share count and fold the new
         shares' cost into the basis. *)
      { t with
        shares = t.shares + delta
      ; cost_basis_cents = t.cost_basis_cents + (price_cents * delta)
      }
    else (
      (* Reducing, fully closing, or flipping the position. This is where
         realized P&L is booked. *)
      let avg = t.cost_basis_cents / t.shares in
      let closing = Int.min (Int.abs delta) (Int.abs t.shares) in
      let direction = Sign.to_int (Int.sign t.shares) in
      (* Selling a long above its average books a gain; buying a short back
         below its average books a gain. [direction] carries the sign so both
         cases share one formula. *)
      let realized_delta = closing * (price_cents - avg) * direction in
      let new_shares = t.shares + delta in
      let cost_basis_cents =
        if Sign.equal (Int.sign new_shares) (Int.sign t.shares)
        then
          (* Still on the same side (or flat): drop the closed shares' cost. *)
          t.cost_basis_cents - (avg * direction * closing)
        else
          (* Flipped past flat: the leftover shares open a fresh position at
             this price, so the surviving basis is priced entirely here. *)
          price_cents * new_shares
      in
      { t with
        shares = new_shares
      ; cost_basis_cents
      ; realized_cents = t.realized_cents + realized_delta
      })
  ;;
end

(* All participants' books: participant -> symbol -> position. *)
type t = Position.t Symbol_id.Map.t Participant.Map.t

let empty : t = Participant.Map.empty

(* Update the single [(participant, symbol)] cell, defaulting to an empty
   position when the participant or symbol is new. *)
let update_cell t ~participant ~symbol ~f : t =
  Map.update t participant ~f:(fun by_symbol ->
    let by_symbol = Option.value by_symbol ~default:Symbol_id.Map.empty in
    Map.update by_symbol symbol ~f:(fun position ->
      f (Option.value position ~default:Position.empty)))
;;

let apply_fill t (fill : Fill.t) : t =
  let t =
    update_cell
      t
      ~participant:fill.aggressor_participant
      ~symbol:fill.symbol
      ~f:(fun position ->
        Position.apply_execution
          position
          ~side:fill.aggressor_side
          ~price:fill.price
          ~size:fill.size)
  in
  update_cell
    t
    ~participant:fill.resting_participant
    ~symbol:fill.symbol
    ~f:(fun position ->
      Position.apply_execution
        position
        ~side:(Side.flip fill.aggressor_side)
        ~price:fill.price
        ~size:fill.size)
;;

module Trade_report = struct
  type t =
    { symbol : Symbol_id.t
    ; price : Price.t
    }
  [@@deriving sexp_of]

  let of_exchange_event : Exchange_event.t -> t option = function
    | Trade_report { symbol; price; size = _ } -> Some { symbol; price }
    | Order_accept _ | Fill _ | Order_cancel _ | Order_reject _
    | Best_bid_offer_update _ | Cancel_reject _ ->
      None
  ;;
end

let apply_trade_report t (report : Trade_report.t) : t =
  Map.map t ~f:(fun by_symbol ->
    Map.change by_symbol report.symbol ~f:(function
      | None -> None
      | Some (position : Position.t) ->
        Some { position with reference_price = Some report.price }))
;;

module Summary = struct
  type per_symbol =
    { symbol : Symbol_id.t
    ; position : int
    ; average_entry_price : Price.t option
    ; reference_price : Price.t option
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

let summarize_position ~symbol (position : Position.t) : Summary.per_symbol =
  let average_entry_price =
    if position.shares = 0
    then None
    else
      Some (Price.of_int_cents (position.cost_basis_cents / position.shares))
  in
  (* Compute unrealized from the exact cost basis rather than the rounded
     average: [shares * ref - cost_basis = shares * (ref - avg)]. *)
  let unrealized_cents =
    match position.reference_price with
    | None -> 0
    | Some reference ->
      (position.shares * Price.to_int_cents reference)
      - position.cost_basis_cents
  in
  { symbol
  ; position = position.shares
  ; average_entry_price
  ; reference_price = position.reference_price
  ; realized_cents = position.realized_cents
  ; unrealized_cents
  }
;;

let summary t participant : Summary.t =
  let by_symbol =
    Map.find t participant |> Option.value ~default:Symbol_id.Map.empty
  in
  let per_symbol =
    Map.to_alist by_symbol
    |> List.map ~f:(fun (symbol, position) ->
      summarize_position ~symbol position)
  in
  let total_realized_cents =
    List.sum (module Int) per_symbol ~f:(fun s -> s.realized_cents)
  in
  let total_unrealized_cents =
    List.sum (module Int) per_symbol ~f:(fun s -> s.unrealized_cents)
  in
  { per_symbol; total_realized_cents; total_unrealized_cents }
;;
