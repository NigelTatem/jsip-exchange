open! Core
open Jsip_types
open Jsip_pnl
open Jsip_test_harness
open Harness

(* Build a fill from the aggressor's point of view. The aggressor trades on
   [side]; the resting participant is on the opposite side. Ids are arbitrary
   — P&L only cares about participant, symbol, side, price, size. *)
let fill ~aggressor ~side ~resting ~price_cents ~size : Fill.t =
  { fill_id = 1
  ; symbol = aapl
  ; price = Price.of_int_cents price_cents
  ; size = Size.of_int size
  ; aggressor_order_id = Order_id.of_string "1"
  ; aggressor_participant = aggressor
  ; aggressor_side = side
  ; resting_order_id = Order_id.of_string "2"
  ; resting_participant = resting
  ; aggressor_client_order_id = 0
  ; resting_client_order_id = 0
  }
;;

let print_summary label t participant =
  print_s
    [%message
      label
        ~_:(Participant.to_string participant : string)
        ~summary:(Pnl.summary t participant : Pnl.Summary.t)]
;;

let%expect_test "long: open, add, mark, partially close" =
  (* Alice lifts Bob's offer twice, building a 200-share long at an average
     of $151, then a trade print marks it up, then she sells half. *)
  let t = Pnl.empty in
  let t =
    Pnl.apply_fill
      t
      (fill
         ~aggressor:alice
         ~side:Buy
         ~resting:bob
         ~price_cents:15000
         ~size:100)
  in
  let t =
    Pnl.apply_fill
      t
      (fill
         ~aggressor:alice
         ~side:Buy
         ~resting:bob
         ~price_cents:15200
         ~size:100)
  in
  print_summary "after buys" t alice;
  [%expect
    {|
    ("after buys" Alice
     (summary
      ((per_symbol
        (((symbol AAPL) (position 200) (average_entry_price (15100))
          (reference_price ()) (realized_cents 0) (unrealized_cents 0))))
       (total_realized_cents 0) (total_unrealized_cents 0))))
    |}];
  (* Public print at $155 refreshes the reference price for unrealized P&L. *)
  let t =
    Pnl.apply_trade_report
      t
      { symbol = aapl; price = Price.of_int_cents 15500 }
  in
  print_summary "after $155 print" t alice;
  [%expect
    {|
    ("after $155 print" Alice
     (summary
      ((per_symbol
        (((symbol AAPL) (position 200) (average_entry_price (15100))
          (reference_price (15500)) (realized_cents 0) (unrealized_cents 80000))))
       (total_realized_cents 0) (total_unrealized_cents 80000))))
    |}];
  (* Alice sells 50 at $160 into Charlie, realizing gains on the closed
     shares while keeping 150 open. *)
  let t =
    Pnl.apply_fill
      t
      (fill
         ~aggressor:alice
         ~side:Sell
         ~resting:charlie
         ~price_cents:16000
         ~size:50)
  in
  print_summary "after selling 50 @ $160" t alice;
  [%expect
    {|
    ("after selling 50 @ $160" Alice
     (summary
      ((per_symbol
        (((symbol AAPL) (position 150) (average_entry_price (15100))
          (reference_price (15500)) (realized_cents 45000)
          (unrealized_cents 60000))))
       (total_realized_cents 45000) (total_unrealized_cents 60000))))
    |}]
;;

let%expect_test "resting short side is tracked too" =
  (* The same first fill leaves Bob short 100 @ $150 (he sold). A print at
     $148 should show him an unrealized gain. *)
  let t = Pnl.empty in
  let t =
    Pnl.apply_fill
      t
      (fill
         ~aggressor:alice
         ~side:Buy
         ~resting:bob
         ~price_cents:15000
         ~size:100)
  in
  let t =
    Pnl.apply_trade_report
      t
      { symbol = aapl; price = Price.of_int_cents 14800 }
  in
  print_summary "bob short, marked $148" t bob;
  [%expect
    {|
    ("bob short, marked $148" Bob
     (summary
      ((per_symbol
        (((symbol AAPL) (position -100) (average_entry_price (15000))
          (reference_price (14800)) (realized_cents 0) (unrealized_cents 20000))))
       (total_realized_cents 0) (total_unrealized_cents 20000))))
    |}]
;;
