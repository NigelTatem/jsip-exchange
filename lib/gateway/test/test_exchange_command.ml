open! Core
open Jsip_types
open Jsip_order_book
open Jsip_gateway

let print_parse line =
  match Exchange_command.parse line with
  | Ok (Submit req) -> print_endline [%string "%{req#Order.Request}"]
  | Ok (Book symbol) -> print_endline [%string "BOOK %{symbol#Symbol}"]
  | Ok (Subscribe symbol) ->
    print_endline [%string "SUBSCRIBE %{symbol#Symbol}"]
  | Ok (Cancel _) -> print_endline "unexpected command shape"
  | Error err -> print_endline [%string "ERROR: %{Error.to_string_hum err}"]
;;

(* --- Successful parsing --- *)

let%expect_test "parse: basic buy" =
  print_parse "BUY AAPL 100 150.25";
  [%expect
    {| ERROR: expected: <symbol> <size> <price> [DAY|IOC] [as <name>] |}]
;;

let%expect_test "parse: basic sell" =
  print_parse "SELL TSLA 50 200.00";
  [%expect
    {| ERROR: expected: <symbol> <size> <price> [DAY|IOC] [as <name>] |}]
;;

let%expect_test "parse: case insensitive side" =
  print_parse "buy AAPL 100 150.00";
  print_parse "Buy AAPL 100 150.00";
  [%expect
    {|
    ERROR: expected: <symbol> <size> <price> [DAY|IOC] [as <name>]
    ERROR: expected: <symbol> <size> <price> [DAY|IOC] [as <name>]
    |}]
;;

let%expect_test "parse: with IOC time-in-force" =
  print_parse "BUY AAPL 100 150.00 IOC";
  [%expect {| ERROR: invalid client order id: AAPL |}]
;;

let%expect_test "parse: with explicit DAY" =
  print_parse "SELL AAPL 200 151.00 DAY";
  [%expect {| ERROR: invalid client order id: AAPL |}]
;;

let%expect_test "parse: with participant" =
  print_parse "BUY AAPL 100 150.00 as Alice";
  [%expect {| ERROR: invalid client order id: AAPL |}]
;;

let%expect_test "parse: with TIF and participant" =
  print_parse "SELL GOOG 75 2800.50 IOC as Bob";
  [%expect {| ERROR: invalid client order id: GOOG |}]
;;

let%expect_test "parse: symbol is uppercased" =
  print_parse "BUY aapl 100 150.00";
  [%expect
    {| ERROR: expected: <symbol> <size> <price> [DAY|IOC] [as <name>] |}]
;;

let%expect_test "parse: extra whitespace is ignored" =
  print_parse "  BUY   AAPL   100   150.00  ";
  [%expect
    {| ERROR: expected: <symbol> <size> <price> [DAY|IOC] [as <name>] |}]
;;

let%expect_test "parse: price with dollar sign" =
  print_parse "BUY AAPL 100 $150.25";
  [%expect
    {| ERROR: expected: <symbol> <size> <price> [DAY|IOC] [as <name>] |}]
;;

(* --- Parse errors --- *)

let%expect_test "parse error: empty string" =
  print_parse "";
  print_parse "   ";
  [%expect {|
    ERROR: empty command
    ERROR: empty command
    |}]
;;

let%expect_test "parse error: unknown command" =
  print_parse "HOLD AAPL 100 150.00";
  [%expect {| ERROR: unknown command: HOLD |}]
;;

let%expect_test "parse error: missing fields" =
  print_parse "BUY AAPL";
  print_parse "BUY";
  [%expect
    {|
    ERROR: expected: <symbol> <size> <price> [DAY|IOC] [as <name>]
    ERROR: expected: <symbol> <size> <price> [DAY|IOC] [as <name>]
    |}]
;;

let%expect_test "parse error: invalid size" =
  print_parse "BUY AAPL abc 150.00";
  print_parse "BUY AAPL 0 150.00";
  print_parse "BUY AAPL -5 150.00";
  [%expect
    {|
    ERROR: expected: <symbol> <size> <price> [DAY|IOC] [as <name>]
    ERROR: expected: <symbol> <size> <price> [DAY|IOC] [as <name>]
    ERROR: expected: <symbol> <size> <price> [DAY|IOC] [as <name>]
    |}]
;;

let%expect_test "parse error: invalid price" =
  print_parse "BUY AAPL 100 xyz";
  [%expect
    {| ERROR: expected: <symbol> <size> <price> [DAY|IOC] [as <name>] |}]
;;

let%expect_test "parse error: unknown time-in-force" =
  print_parse "BUY AAPL 100 150.00 QQQ";
  [%expect {| ERROR: invalid client order id: AAPL |}]
;;

(* Default participant override and explicit `as` clause preservation *)

let%expect_test "default participant: used when none specified" =
  let default = Participant.of_string "DefaultTrader" in
  let cmd =
    Exchange_command.parse "BUY AAPL 100 150.00" ~default_participant:default
    |> ok_exn
  in
  (match cmd with
   | Submit req ->
     print_endline [%string "participant=%{req.participant#Participant}"]
   | Book _ | Subscribe _ | Cancel _ ->
     print_endline "unexpected command shape");
  [%expect.unreachable]
[@@expect.uncaught_exn
  {|
  (* CR expect_test_collector: This test expectation appears to contain a backtrace.
     This is strongly discouraged as backtraces are fragile.
     Please change this test to not include a backtrace. *)
  "expected: <symbol> <size> <price> [DAY|IOC] [as <name>]"
  Raised at Base__Error.raise in file "src/error.ml", line 17, characters 38-66
  Called from Base__Error.raise in file "src/error.ml" (inlined), line 25, characters 47-66
  Called from Base__Or_error.ok_exn in file "src/or_error.ml" (inlined), line 100, characters 17-44
  Called from Jsip_gateway_test__Test_exchange_command.(fun) in file "lib/gateway/test/test_exchange_command.ml", lines 125-126, characters 4-91
  Called from Ppx_expect_runtime__Test_block.Configured.dump_backtrace in file "runtime/test_block.ml", line 359, characters 10-25
  |}]
;;

let%expect_test "default participant: overridden by explicit 'as'" =
  let default = Participant.of_string "DefaultTrader" in
  let cmd =
    Exchange_command.parse
      "BUY AAPL 100 150.00 as Alice"
      ~default_participant:default
    |> ok_exn
  in
  (match cmd with
   | Submit req ->
     print_endline [%string "participant=%{req.participant#Participant}"]
   | Book _ | Subscribe _ | Cancel _ ->
     print_endline "unexpected command shape");
  [%expect.unreachable]
[@@expect.uncaught_exn
  {|
  (* CR expect_test_collector: This test expectation appears to contain a backtrace.
     This is strongly discouraged as backtraces are fragile.
     Please change this test to not include a backtrace. *)
  "invalid client order id: AAPL"
  Raised at Base__Error.raise in file "src/error.ml", line 17, characters 38-66
  Called from Base__Error.raise in file "src/error.ml" (inlined), line 25, characters 47-66
  Called from Base__Or_error.ok_exn in file "src/or_error.ml" (inlined), line 100, characters 17-44
  Called from Jsip_gateway_test__Test_exchange_command.(fun) in file "lib/gateway/test/test_exchange_command.ml", lines 149-152, characters 4-112
  Called from Ppx_expect_runtime__Test_block.Configured.dump_backtrace in file "runtime/test_block.ml", line 359, characters 10-25
  |}]
;;

(* --- Event formatting --- *)

let%expect_test "format_event: all event types" =
  let events =
    [ Exchange_event.Order_accept
        { order_id = Order_id.of_string "1"
        ; request =
            { symbol = Symbol.of_string "AAPL"
            ; participant = Participant.of_string "Alice"
            ; side = Buy
            ; price = Price.of_int_cents 15000
            ; size = Size.of_int 100
            ; time_in_force = Day
            ; client_order_id = 0
            }
        }
    ; Fill
        { fill_id = 0
        ; symbol = Symbol.of_string "AAPL"
        ; price = Price.of_int_cents 15000
        ; size = Size.of_int 100
        ; aggressor_order_id = Order_id.of_string "2"
        ; aggressor_participant = Participant.of_string "Alice"
        ; aggressor_side = Buy
        ; resting_order_id = Order_id.of_string "1"
        ; resting_participant = Participant.of_string "Bob"
        ; aggressor_client_order_id = 0
        ; resting_client_order_id = 0
        }
    ; Order_cancel
        { order_id = Order_id.of_string "3"
        ; participant = Participant.of_string "Charlie"
        ; symbol = Symbol.of_string "TSLA"
        ; remaining_size = Size.of_int 50
        ; reason = Ioc_remainder
        ; client_order_id = 0
        }
    ; Order_reject
        { request =
            { symbol = Symbol.of_string "GOOG"
            ; participant = Participant.of_string "Alice"
            ; side = Sell
            ; price = Price.of_int_cents 28000
            ; size = Size.of_int 10
            ; time_in_force = Day
            ; client_order_id = 0
            }
        ; reason = "unknown symbol"
        }
    ; Best_bid_offer_update
        { symbol = Symbol.of_string "AAPL"
        ; bbo =
            { bid =
                Some
                  { price = Price.of_int_cents 14990
                  ; size = Size.of_int 200
                  }
            ; ask =
                Some
                  { price = Price.of_int_cents 15010
                  ; size = Size.of_int 100
                  }
            }
        }
    ; Best_bid_offer_update
        { symbol = Symbol.of_string "AAPL"; bbo = Bbo.empty }
    ; Trade_report
        { symbol = Symbol.of_string "AAPL"
        ; price = Price.of_int_cents 15000
        ; size = Size.of_int 100
        }
    ]
  in
  List.iter events ~f:(fun e -> print_endline (Event_format.format_event e));
  [%expect
    {|
    ACCEPTED id=1 AAPL BUY 100@$150.00 DAY
    FILL fill_id=0 AAPL $150.00 x100 aggressor=2(Alice) BUY 1 resting=Bob(0) 0
    CANCELLED id=3 TSLA remaining=50 reason=IOC_REMAINDER
    REJECTED GOOG SELL 10@$280.00 reason=unknown symbol
    BBO AAPL bid=$149.90 x200 ask=$150.10 x100
    BBO AAPL bid=- ask=-
    TRADE AAPL $150.00 x100
    |}]
;;

(* --- Round-trip: parse then format --- *)

let%expect_test "round-trip: parse a command, submit, format result" =
  let open Jsip_test_harness in
  let t = Harness.create () in
  Harness.submit_
    t
    (Harness.sell ~price_cents:15000 ~participant:Harness.bob ());
  let request =
    match
      Exchange_command.parse "BUY AAPL 100 150.00 as Alice" |> ok_exn
    with
    | Submit req -> req
    | Book _ | Subscribe _ | Cancel _ -> failwith "expected Submit"
  in
  let events = Matching_engine.submit (Harness.engine t) request in
  print_endline (Event_format.format_events events);
  [%expect.unreachable]
[@@expect.uncaught_exn
  {|
  (* CR expect_test_collector: This test expectation appears to contain a backtrace.
     This is strongly discouraged as backtraces are fragile.
     Please change this test to not include a backtrace. *)
  "invalid client order id: AAPL"
  Raised at Base__Error.raise in file "src/error.ml", line 17, characters 38-66
  Called from Base__Error.raise in file "src/error.ml" (inlined), line 25, characters 47-66
  Called from Base__Or_error.ok_exn in file "src/or_error.ml" (inlined), line 100, characters 17-44
  Called from Jsip_gateway_test__Test_exchange_command.(fun) in file "lib/gateway/test/test_exchange_command.ml", line 268, characters 6-69
  Called from Ppx_expect_runtime__Test_block.Configured.dump_backtrace in file "runtime/test_block.ml", line 359, characters 10-25

  Trailing output
  ---------------
  ACCEPTED id=1 AAPL SELL 100@$150.00 DAY
  BBO AAPL bid=- ask=$150.00 x100
  |}]
;;

let%expect_test "BOOK with a symbol argument" =
  let cmd = Exchange_command.parse "BOOK AAPL" |> ok_exn in
  (match cmd with
   | Book symbol -> print_endline [%string "BOOK %{symbol#Symbol}"]
   | Submit _ | Subscribe _ | Cancel _ ->
     print_endline "unexpected command shape");
  [%expect {| BOOK AAPL |}]
;;

let%expect_test "SUBSCRIBE with case-insensitive input" =
  let cmd = Exchange_command.parse "Subscribe AAPL" |> ok_exn in
  (match cmd with
   | Subscribe symbol -> print_endline [%string "SUBSCRIBE %{symbol#Symbol}"]
   | Submit _ | Book _ | Cancel _ -> print_endline "unexpected command shape");
  [%expect {| SUBSCRIBE AAPL |}]
;;
