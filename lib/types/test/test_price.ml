open! Core
open Jsip_types

let%expect_test "of_int_cents and to_int_cents round-trip" =
  [%test_result: int]
    (Price.to_int_cents (Price.of_int_cents 15025))
    ~expect:15025
;;

let%expect_test "to_float: converts cents to dollars" =
  [%test_result: float]
    (Price.to_float (Price.of_int_cents 15025))
    ~expect:150.25;
  [%test_result: float] (Price.to_float (Price.of_int_cents 100)) ~expect:1.0;
  [%test_result: float] (Price.to_float (Price.of_int_cents 0)) ~expect:0.0
;;

let%expect_test "of_float_exn: converts dollar amount to cents" =
  [%test_result: int]
    (Price.to_int_cents (Price.of_float_exn 150.25))
    ~expect:15025;
  [%test_result: int]
    (Price.to_int_cents (Price.of_float_exn 1.0))
    ~expect:100;
  [%test_result: int]
    (Price.to_int_cents (Price.of_float_exn 0.01))
    ~expect:1
;;

let%expect_test "to_string_dollar: formatted display" =
  print_endline (Price.to_string_dollar (Price.of_int_cents 15025));
  print_endline (Price.to_string_dollar (Price.of_int_cents 100));
  print_endline (Price.to_string_dollar (Price.of_int_cents 5));
  print_endline (Price.to_string_dollar (Price.of_int_cents 0));
  [%expect {|
    $150.25
    $1.00
    $0.05
    $0.00
    |}]
;;

let%expect_test "of_string: parses dollar amounts with or without $" =
  [%test_result: int]
    (Price.to_int_cents (Price.of_string "150.25"))
    ~expect:15025;
  [%test_result: int]
    (Price.to_int_cents (Price.of_string "$150.25"))
    ~expect:15025;
  [%test_result: int]
    (Price.to_int_cents (Price.of_string "1.00"))
    ~expect:100
;;

let%expect_test "arithmetic: addition and subtraction" =
  let a = Price.of_int_cents 1500 in
  let b = Price.of_int_cents 250 in
  [%test_result: Price.t] Price.(a + b) ~expect:(Price.of_int_cents 1750);
  [%test_result: Price.t] Price.(a - b) ~expect:(Price.of_int_cents 1250)
;;

let%expect_test "arithmetic: multiplication by quantity" =
  let price = Price.of_int_cents 1500 in
  [%test_result: int] (Price.to_int_cents Price.(price * 100)) ~expect:150000
;;

let%expect_test "zero: is zero" =
  [%test_result: Price.t] Price.zero ~expect:(Price.of_int_cents 0)
;;

let%expect_test "negative to_string_dollar" =
  print_endline (Price.to_string_dollar (Price.of_int_cents (-1)));
  [%expect {| -$0.01 |}];
  print_endline (Price.to_string_dollar (Price.of_int_cents (-150)));
  [%expect {| -$1.50 |}]
;;

let%expect_test "is_more_aggressive: lower buy" =
  let price = Price.of_int_cents 0 in
  let than = Price.of_int_cents 1 in
  let result = Price.is_more_aggressive Side.Buy ~price ~than in
  [%test_result: bool] result ~expect:false
;;

let%expect_test "is_more_aggressive: higher buy" =
  let price = Price.of_int_cents 1 in
  let than = Price.of_int_cents 0 in
  let result = Price.is_more_aggressive Side.Buy ~price ~than in
  [%test_result: bool] result ~expect:true
;;

let%expect_test "is_more_aggressive: equal buy" =
  let price = Price.of_int_cents 0 in
  let than = Price.of_int_cents 0 in
  let result = Price.is_more_aggressive Side.Buy ~price ~than in
  [%test_result: bool] result ~expect:false
;;

let%expect_test "is_more_aggressive: lower sell" =
  let price = Price.of_int_cents 0 in
  let than = Price.of_int_cents 1 in
  let result = Price.is_more_aggressive Side.Sell ~price ~than in
  [%test_result: bool] result ~expect:true
;;

let%expect_test "is_more_aggressive: higher sell" =
  let price = Price.of_int_cents 1 in
  let than = Price.of_int_cents 0 in
  let result = Price.is_more_aggressive Side.Sell ~price ~than in
  [%test_result: bool] result ~expect:false
;;

let%expect_test "is_more_aggressive: equal sell" =
  let price = Price.of_int_cents 0 in
  let than = Price.of_int_cents 0 in
  let result = Price.is_more_aggressive Side.Sell ~price ~than in
  [%test_result: bool] result ~expect:false
;;

let%expect_test "is_marketable: equal buy" =
  let price = Price.of_int_cents 0 in
  let resting_price = Price.of_int_cents 0 in
  let result = Price.is_marketable Side.Buy ~price ~resting_price in
  [%test_result: bool] result ~expect:true
;;

let%expect_test "is_marketable: higher buy" =
  let price = Price.of_int_cents 1 in
  let resting_price = Price.of_int_cents 0 in
  let result = Price.is_marketable Side.Buy ~price ~resting_price in
  [%test_result: bool] result ~expect:true
;;

let%expect_test "is_marketable: lower buy" =
  let price = Price.of_int_cents 0 in
  let resting_price = Price.of_int_cents 1 in
  let result = Price.is_marketable Side.Buy ~price ~resting_price in
  [%test_result: bool] result ~expect:false
;;

let%expect_test "is_marketable: equal sell" =
  let price = Price.of_int_cents 0 in
  let resting_price = Price.of_int_cents 0 in
  let result = Price.is_marketable Side.Sell ~price ~resting_price in
  [%test_result: bool] result ~expect:true
;;

let%expect_test "is_marketable: higher sell" =
  let price = Price.of_int_cents 1 in
  let resting_price = Price.of_int_cents 0 in
  let result = Price.is_marketable Side.Sell ~price ~resting_price in
  [%test_result: bool] result ~expect:false
;;

let%expect_test "is_marketable: lower sell" =
  let price = Price.of_int_cents 0 in
  let resting_price = Price.of_int_cents 1 in
  let result = Price.is_marketable Side.Sell ~price ~resting_price in
  [%test_result: bool] result ~expect:true
;;
