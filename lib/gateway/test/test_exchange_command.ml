open! Core
open Jsip_types
open Jsip_order_book
open Jsip_gateway

let print_parse line =
  match Exchange_command.parse line ~directory:Symbol_directory.empty with
  | Ok (Submit req) -> print_endline [%string "%{req#Order.Request}"]
  | Ok (Book symbol) -> print_endline [%string "BOOK %{symbol#Symbol_id}"]
  | Ok (Subscribe symbol) ->
    print_endline [%string "SUBSCRIBE %{symbol#Symbol_id}"]
  | Ok (Cancel id) ->
    print_endline [%string "CANCEL %{Client_order_id.to_int id#Int}"]
  | Ok Stats -> print_endline "STATS"
  | Error err -> print_endline [%string "ERROR: %{Error.to_string_hum err}"]
;;

(* --- Successful parsing --- *)

let%expect_test "parse: stats" =
  print_parse "STATS";
  [%expect {| STATS |}];
  print_parse "stats";
  [%expect {| STATS |}];
  print_parse "STATS AAPL";
  [%expect {| ERROR: unexpected trailing arguments: AAPL |}]
;;

let%expect_test "parse: basic buy" =
  print_parse "BUY 1 0 100 150.25";
  [%expect {| BUY 0 100@$150.25 DAY as anonymous |}]
;;

let%expect_test "parse: basic sell" =
  print_parse "SELL 2 1 50 200.00";
  [%expect {| SELL 1 50@$200.00 DAY as anonymous |}]
;;

let%expect_test "parse: case insensitive side" =
  print_parse "buy 1 0 100 150.00";
  print_parse "Buy 1 0 100 150.00";
  [%expect
    {|
    BUY 0 100@$150.00 DAY as anonymous
    BUY 0 100@$150.00 DAY as anonymous
    |}]
;;

let%expect_test "parse: with IOC time-in-force" =
  print_parse "BUY 1 0 100 150.00 IOC";
  [%expect {| BUY 0 100@$150.00 IOC as anonymous |}]
;;

let%expect_test "parse: with explicit DAY" =
  print_parse "SELL 3 0 200 151.00 DAY";
  [%expect {| SELL 0 200@$151.00 DAY as anonymous |}]
;;

let%expect_test "parse: extra whitespace is ignored" =
  print_parse "  BUY   1   0   100   150.00  ";
  [%expect {| BUY 0 100@$150.00 DAY as anonymous |}]
;;

let%expect_test "parse: price with dollar sign" =
  print_parse "BUY 1 0 100 $150.25";
  [%expect {| BUY 0 100@$150.25 DAY as anonymous |}]
;;

let%expect_test "parse: cancel by client order id" =
  print_parse "CANCEL 42";
  [%expect {| CANCEL 42 |}]
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
  print_parse "HOLD 1 AAPL 100 150.00";
  [%expect {| ERROR: unknown command: HOLD |}]
;;

let%expect_test "parse error: missing fields" =
  print_parse "BUY 1 AAPL";
  print_parse "BUY";
  [%expect
    {|
    ERROR: expected: <client_id> <symbol> <size> <price> [DAY|IOC]
    ERROR: expected: <client_id> <symbol> <size> <price> [DAY|IOC]
    |}]
;;

let%expect_test "parse error: invalid client order id" =
  print_parse "BUY x AAPL 100 150.00";
  [%expect {| ERROR: invalid client order id: x |}]
;;

let%expect_test "parse error: invalid size" =
  print_parse "BUY 1 AAPL abc 150.00";
  print_parse "BUY 1 AAPL 0 150.00";
  print_parse "BUY 1 AAPL -5 150.00";
  [%expect
    {|
    ERROR: invalid size: abc
    ERROR: size must be positive
    ERROR: size must be positive
    |}]
;;

let%expect_test "parse error: invalid price" =
  print_parse "BUY 1 AAPL 100 xyz";
  [%expect {| ERROR: (Invalid_argument "Float.of_string xyz") |}]
;;

let%expect_test "parse error: unknown time-in-force" =
  print_parse "BUY 1 0 100 150.00 QQQ";
  [%expect {| ERROR: unknown time-in-force: QQQ (expected DAY|IOC) |}]
;;

let%expect_test "default participant: used when none specified" =
  let default = Participant.of_string "DefaultTrader" in
  let cmd =
    Exchange_command.parse
      "BUY 1 0 100 150.00"
      ~default_participant:default
      ~directory:Symbol_directory.empty
    |> ok_exn
  in
  (match cmd with
   | Submit req ->
     print_endline [%string "participant=%{req.participant#Participant}"]
   | Book _ | Subscribe _ | Cancel _ | Stats ->
     print_endline "unexpected command shape");
  [%expect {| participant=DefaultTrader |}]
;;

(* --- Event formatting --- *)

let%expect_test "format_event: all event types" =
  let events =
    [ Exchange_event.Order_accept
        { order_id = Order_id.of_string "1"
        ; request =
            { symbol = Symbol_id.of_int 0
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
        ; symbol = Symbol_id.of_int 0
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
        ; symbol = Symbol_id.of_int 1
        ; remaining_size = Size.of_int 50
        ; reason = Ioc_remainder
        ; client_order_id = 0
        }
    ; Order_reject
        { request =
            { symbol = Symbol_id.of_int 2
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
        { symbol = Symbol_id.of_int 0
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
    ; Best_bid_offer_update { symbol = Symbol_id.of_int 0; bbo = Bbo.empty }
    ; Trade_report
        { symbol = Symbol_id.of_int 0
        ; price = Price.of_int_cents 15000
        ; size = Size.of_int 100
        }
    ]
  in
  List.iter events ~f:(fun e ->
    print_endline
      (Event_format.format_event ~render_symbol:Symbol_id.to_string e));
  [%expect
    {|
    ACCEPTED id=1 0 BUY 100@$150.00 DAY
    FILL fill_id=0 0 $150.00 x100 aggressor=2(Alice) BUY 1 resting=Bob(0) 0
    CANCELLED id=3 1 remaining=50 reason=IOC_REMAINDER
    REJECTED 2 SELL 10@$280.00 reason=unknown symbol
    BBO 0 bid=$149.90 x200 ask=$150.10 x100
    BBO 0 bid=- ask=-
    TRADE 0 $150.00 x100
    |}]
;;

(* --- Round-trip: parse then format --- *)

let%expect_test "round-trip: parse a command, submit, format result" =
  let open Jsip_test_harness in
  let t = Harness.create () in
  Harness.submit_
    t
    (Harness.sell
       ~price_cents:15000
       ~client_order_id:1
       ~participant:Harness.bob
       ());
  let request =
    match
      Exchange_command.parse
        "BUY 2 0 100 150.00"
        ~directory:Symbol_directory.empty
      |> ok_exn
    with
    | Submit req -> req
    | Book _ | Subscribe _ | Cancel _ | Stats -> failwith "expected Submit"
  in
  let events = Matching_engine.submit (Harness.engine t) request in
  print_endline
    (Event_format.format_events ~render_symbol:Symbol_id.to_string events);
  [%expect
    {|
    ACCEPTED id=1 0 SELL 100@$150.00 DAY
    BBO 0 bid=- ask=$150.00 x100
    ACCEPTED id=2 0 BUY 100@$150.00 DAY
    FILL fill_id=1 0 $150.00 x100 aggressor=2(anonymous) BUY 1 resting=Bob(2) 1
    TRADE 0 $150.00 x100
    BBO 0 bid=- ask=-
    |}]
;;

let%expect_test "BOOK with a symbol argument" =
  let cmd =
    Exchange_command.parse "BOOK 0" ~directory:Symbol_directory.empty
    |> ok_exn
  in
  (match cmd with
   | Book symbol -> print_endline [%string "BOOK %{symbol#Symbol_id}"]
   | Submit _ | Subscribe _ | Cancel _ | Stats ->
     print_endline "unexpected command shape");
  [%expect {| BOOK 0 |}]
;;

let%expect_test "SUBSCRIBE with case-insensitive input" =
  let cmd =
    Exchange_command.parse "Subscribe 0" ~directory:Symbol_directory.empty
    |> ok_exn
  in
  (match cmd with
   | Subscribe symbol ->
     print_endline [%string "SUBSCRIBE %{symbol#Symbol_id}"]
   | Submit _ | Book _ | Cancel _ | Stats ->
     print_endline "unexpected command shape");
  [%expect {| SUBSCRIBE 0 |}]
;;

(* --- Phase 2: resolving symbol names through a directory --- *)

let directory =
  Symbol_directory.of_names
    [ Symbol.of_string "AAPL"
    ; Symbol.of_string "TSLA"
    ; Symbol.of_string "GOOG"
    ]
;;

let print_parse_with_directory line =
  match Exchange_command.parse line ~directory with
  | Ok (Submit req) -> print_endline [%string "%{req#Order.Request}"]
  | Ok (Book symbol) -> print_endline [%string "BOOK %{symbol#Symbol_id}"]
  | Ok (Subscribe symbol) ->
    print_endline [%string "SUBSCRIBE %{symbol#Symbol_id}"]
  | Ok (Cancel id) ->
    print_endline [%string "CANCEL %{Client_order_id.to_int id#Int}"]
  | Ok Stats -> print_endline "STATS"
  | Error err -> print_endline [%string "ERROR: %{Error.to_string_hum err}"]
;;

let%expect_test "parse: a human name resolves to its id" =
  (* [TSLA] is id 1 in the directory, so the wire-level command carries 1. *)
  print_parse_with_directory "BUY 1 TSLA 100 150.25";
  [%expect {| BUY 1 100@$150.25 DAY as anonymous |}];
  print_parse_with_directory "BOOK AAPL";
  [%expect {| BOOK 0 |}];
  print_parse_with_directory "SUBSCRIBE GOOG";
  [%expect {| SUBSCRIBE 2 |}]
;;

let%expect_test "parse: unknown symbol name is rejected" =
  print_parse_with_directory "BOOK ZZZZ";
  [%expect {| ERROR: unknown symbol: ZZZZ |}];
  print_parse_with_directory "BUY 1 NOPE 100 150.00";
  [%expect {| ERROR: unknown symbol: NOPE |}]
;;

let%expect_test "parse: a raw id still works alongside names" =
  (* Fallback path: an int is accepted directly, so old int-style commands
     and a directory coexist. Range-checking the id is the server's job. *)
  print_parse_with_directory "BOOK 1";
  [%expect {| BOOK 1 |}]
;;
