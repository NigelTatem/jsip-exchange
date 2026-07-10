open! Core
open Jsip_types

(* Ex 4 ships a [Symbol_id.t] (int) on the wire where Ex 1-3 shipped a
   [Symbol.t] (string). These are deterministic [bin_prot] byte counts, so
   they belong in an expect test: multiplied across every order and every
   streamed event, the per-message shrink is real bandwidth.

   The point of comparison is the symbol field itself. A small int encodes in
   one byte; a 4-char name is a length byte plus its characters. Every
   message that carries a symbol carries that difference. *)

let symbol_id : Symbol_id.t = Symbol_id.of_int 0
let symbol_name : Symbol.t = Symbol.of_string "AAPL"

let request : Order.Request.t =
  { symbol = symbol_id
  ; participant = Participant.of_string "Alice"
  ; side = Buy
  ; price = Price.of_int_cents 15000
  ; size = Size.of_int 100
  ; time_in_force = Day
  ; client_order_id = 0
  }
;;

let fill : Fill.t =
  { fill_id = 1
  ; symbol = symbol_id
  ; price = Price.of_int_cents 15000
  ; size = Size.of_int 100
  ; aggressor_order_id = Order_id.of_string "2"
  ; aggressor_participant = Participant.of_string "Alice"
  ; aggressor_side = Buy
  ; aggressor_client_order_id = 0
  ; resting_order_id = Order_id.of_string "1"
  ; resting_participant = Participant.of_string "Bob"
  ; resting_client_order_id = 0
  }
;;

let book : Book.t =
  { symbol = symbol_id; bids = []; asks = []; bbo = Bbo.empty }
;;

let event : Exchange_event.t =
  Trade_report
    { symbol = symbol_id
    ; price = Price.of_int_cents 15000
    ; size = Size.of_int 100
    }
;;

let%expect_test "the symbol field: int vs string on the wire" =
  print_s
    [%message
      ""
        ~symbol_id_bytes:(Symbol_id.bin_size_t symbol_id : int)
        ~symbol_name_bytes:(Symbol.bin_size_t symbol_name : int)];
  [%expect {| ((symbol_id_bytes 1) (symbol_name_bytes 5)) |}]
;;

let%expect_test "per-message bin_io sizes carrying an int symbol" =
  print_s
    [%message
      ""
        ~order_request:(Order.Request.bin_size_t request : int)
        ~book:(Book.bin_size_t book : int)
        ~fill:(Fill.bin_size_t fill : int)
        ~exchange_event:(Exchange_event.bin_size_t event : int)];
  [%expect {| ((order_request 14) (book 5) (fill 21) (exchange_event 6)) |}]
;;
