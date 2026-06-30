(** Tests for the market maker, using a real exchange server. *)

open! Core
open! Async
open Jsip_test_harness
open Jsip_market_maker
open E2e_helpers

let default_config : Market_maker.Config.t =
  { participant = Harness.market_maker
  ; symbol = Harness.aapl
  ; fair_value_cents = 15000
  ; half_spread_cents = 10
  ; size_per_level = 100
  ; num_levels = 3
  ; inventory_skew_cents_per_share = 0
  }
;;

let%expect_test "seed_book: places symmetric bids and asks around fair value"
  =
  with_server ~symbols:[ Harness.aapl ] (fun ~server:_ ~port ->
    let%bind mm = connect_as ~port Harness.market_maker in
    let%bind () = Market_maker.seed_book default_config (connection mm) in
    [%expect
      {|
      [MarketMaker] ACCEPTED id=1 AAPL BUY 100@$149.90 DAY
      [MarketMaker] ACCEPTED id=2 AAPL SELL 100@$150.10 DAY
      [MarketMaker] ACCEPTED id=3 AAPL BUY 100@$149.89 DAY
      [MarketMaker] ACCEPTED id=4 AAPL SELL 100@$150.11 DAY
      [MarketMaker] ACCEPTED id=5 AAPL BUY 100@$149.88 DAY
      [MarketMaker] ACCEPTED id=6 AAPL SELL 100@$150.12 DAY
      |}];
    return ())
;;

(**
let%expect_test "handle_event: tracks inventory and outstanding orders" =
  let state = Market_maker.create_state () in
  (* Accept a buy order with client_order_id=1 *)
  Market_maker.handle_event
    state
    (Order_accept
       { order_id = Order_id.of_int 1
       ; request =
           { symbol = Harness.aapl
           ; participant = Harness.market_maker
           ; side = Buy
           ; price = Price.of_int_cents 14990
           ; size = Size.of_int 100
           ; time_in_force = Day
           ; client_order_id = 1
           }
       });
  (* Accept a sell order with client_order_id=2 *)
  Market_maker.handle_event
    state
    (Order_accept
       { order_id = Order_id.of_int 2
       ; request =
           { symbol = Harness.aapl
           ; participant = Harness.market_maker
           ; side = Sell
           ; price = Price.of_int_cents 15010
           ; size = Size.of_int 100
           ; time_in_force = Day
           ; client_order_id = 2
           }
       });
  printf
    "after accepts: inventory=%d outstanding=%d\n"
    state.inventory
    (Hashtbl.length state.outstanding);
  [%expect {| after accepts: inventory=0 outstanding=2 |}];
  (* Fill: someone buys against our resting sell (id=2), full fill *)
  Market_maker.handle_event
    state
    (Fill
       { fill_id = 1
       ; symbol = Harness.aapl
       ; price = Price.of_int_cents 15010
       ; size = Size.of_int 100
       ; aggressor_order_id = Order_id.of_int 99
       ; aggressor_participant = Participant.of_string "Trader"
       ; aggressor_side = Buy
       ; resting_order_id = Order_id.of_int 2
       ; resting_participant = Harness.market_maker
       ; aggressor_client_order_id = 50
       ; resting_client_order_id = 2
       });
  printf
    "after sell filled: inventory=%d outstanding=%d\n"
    state.inventory
    (Hashtbl.length state.outstanding);
  [%expect {| after sell filled: inventory=-100 outstanding=1 |}];
  (* Cancel the remaining buy (id=1) *)
  Market_maker.handle_event
    state
    (Order_cancel
       { order_id = Order_id.of_int 1
       ; participant = Harness.market_maker
       ; symbol = Harness.aapl
       ; remaining_size = Size.of_int 100
       ; reason = Participant_requested
       ; client_order_id = 1
       });
  printf
    "after cancel: inventory=%d outstanding=%d\n"
    state.inventory
    (Hashtbl.length state.outstanding);
  [%expect {| after cancel: inventory=-100 outstanding=0 |}];
  return ()
;;
*)
