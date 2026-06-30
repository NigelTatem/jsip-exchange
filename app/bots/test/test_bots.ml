(** Scaffolding for bot tests. *)

open! Core
open! Async
open Jsip_types
open Jsip_fundamental
open Jsip_bot_runtime
open! Jsip_bots

let aapl = Symbol.of_string "AAPL"
let alice = Participant.of_string "Alice"

let oracle_config ~initial_price_cents =
  Symbol.Map.of_alist_exn
    [ ( aapl
      , { Fundamental_oracle.Config.initial_price_cents
        ; volatility_cents_per_sec = 0.0
        ; mean_reversion_strength = 0.0
        ; tick_interval = Time_ns.Span.of_sec 1.0
        } )
    ]
;;

(* Build a runtime around a bot module with a mock submit/cancel that records
   what the bot does. *)
let make_recording_bot
  (type cfg)
  (bot_module : (module Bot_runtime.Bot with type Config.t = cfg))
  (config : cfg)
  ?(initial_price_cents = 15000)
  ()
  =
  let submitted = ref [] in
  let cancelled = ref [] in
  let submit request =
    submitted := request :: !submitted;
    return (Ok ())
  in
  let cancel order_id =
    cancelled := order_id :: !cancelled;
    return (Ok ())
  in
  let oracle =
    Fundamental_oracle.create (oracle_config ~initial_price_cents) ~seed:42
  in
  let bot =
    Bot_runtime.create
      bot_module
      config
      ~participant:alice
      ~oracle
      ~rng:(Splittable_random.of_int 7)
      ~dispatch_submit:submit
      ~dispatch_cancel:cancel
      ~tick_interval:(Time_ns.Span.of_sec 1.0)
  in
  bot, submitted, cancelled
;;

let print_submitted (submitted : Order.Request.t list ref) =
  let recent = List.rev !submitted in
  List.iter recent ~f:(fun req ->
    printf
      !"%{Side} %{Symbol} %d@%{Price#dollar} %{Time_in_force}\n"
      req.side
      req.symbol
      (Size.to_int req.size)
      req.price
      req.time_in_force)
;;

(* Smoke test: drive the do-nothing reference bot through one event so the
   runtest target exercises the helpers above. Replace or extend with
   bot-specific tests as concrete strategies are added to [Jsip_bots]. *)
module Inert_bot = struct
  module Config = struct
    type t = unit
  end

  let name = "inert"
  let on_start () _ctx = return ()
  let on_tick () _ctx = return ()
  let on_event () _ctx _event = return ()
end

let%expect_test "make_recording_bot wires up a runnable bot" =
  let bot, submitted, _cancelled =
    make_recording_bot (module Inert_bot) () ()
  in
  let%bind () =
    Bot_runtime.feed_event
      bot
      (Order_accept
         { order_id = Order_id.For_testing.of_int 1
         ; request =
             { symbol = aapl
             ; participant = alice
             ; side = Buy
             ; price = Price.of_int_cents 15000
             ; size = Size.of_int 10
             ; time_in_force = Day
             ; client_order_id = 0
             }
         })
  in
  print_submitted submitted;
  [%expect {| |}];
  return ()
;;

let%expect_test "Market_maker_bot seeds ladder and skews quotes after a fill"
  =
  let config =
    Market_maker_bot.create_config
      ~symbol:aapl
      ~half_spread_cents:5
      ~size_per_level:10
      ~num_levels:2
      ~inventory_skew_cents_per_share:2
  in
  let bot, submitted, cancelled =
    make_recording_bot
      (module Market_maker_bot)
      config
      ~initial_price_cents:10000
      ()
  in
  let ctx = Bot_runtime.For_testing.context_of bot in
  let%bind () = Market_maker_bot.on_start config ctx in
  print_endline "=== Initial Seed Ladder ===";
  print_submitted submitted;
  [%expect
    {|
    === Initial Seed Ladder ===
    Buy AAPL 10@$99.95 Day
    Sell AAPL 10@$100.05 Day
    Buy AAPL 10@$99.94 Day
    Sell AAPL 10@$100.06 Day
  |}];
  submitted := [];
  cancelled := [];
  let mock_fill =
    Exchange_event.Fill
      { symbol = aapl
      ; size = Size.of_int 10
      ; price = Price.of_int_cents 9995
      ; aggressor_client_order_id = 0
      ; resting_client_order_id = 999
      ; fill_id = 1
      ; aggressor_order_id = Order_id.For_testing.of_int 101
      ; aggressor_participant = Participant.of_string "AGGRESSOR"
      ; aggressor_side = Side.Buy
      ; resting_order_id = Order_id.For_testing.of_int 202
      ; resting_participant = alice
      }
  in
  let%bind () = Bot_runtime.feed_event bot mock_fill in
  print_endline "=== Post-Fill Skewed Ladder ===";
  print_submitted submitted;
  [%expect
    {|
    === Post-Fill Skewed Ladder ===
    Buy AAPL 10@$99.75 Day
    Sell AAPL 10@$99.85 Day
    Buy AAPL 10@$99.74 Day
    Sell AAPL 10@$99.86 Day
  |}];
  return ()
;;
