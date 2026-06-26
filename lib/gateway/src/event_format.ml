open! Core
open Jsip_types

let format_event = function
  | Exchange_event.Order_accept { order_id; request } ->
    sprintf
      "ACCEPTED id=%s %s %s %d@%s %s"
      (Order_id.to_string order_id)
      (Symbol.to_string request.symbol)
      (Side.to_string request.side)
      (Size.to_int request.size)
      (Price.to_string_dollar request.price)
      (Time_in_force.to_string request.time_in_force)
  | Fill fill -> [%string "FILL %{fill#Fill}"]
  | Order_cancel
      { order_id
      ; participant = _
      ; symbol
      ; remaining_size
      ; reason
      ; client_order_id = _
      } ->
    sprintf
      "CANCELLED id=%s %s remaining=%d reason=%s"
      (Order_id.to_string order_id)
      (Symbol.to_string symbol)
      (Size.to_int remaining_size)
      (Cancel_reason.to_string reason)
  | Order_reject { request; reason } ->
    sprintf
      "REJECTED %s %s %d@%s reason=%s"
      (Symbol.to_string request.symbol)
      (Side.to_string request.side)
      (Size.to_int request.size)
      (Price.to_string_dollar request.price)
      reason
  | Best_bid_offer_update { symbol; bbo } ->
    let bid = Level.opt_to_string bbo.bid in
    let ask = Level.opt_to_string bbo.ask in
    [%string "BBO %{symbol#Symbol} bid=%{bid} ask=%{ask}"]
  | Trade_report { symbol; price; size } ->
    let size = Size.to_int size in
    [%string "TRADE %{symbol#Symbol} %{price#Price} x%{size#Int}"]
  | Cancel_reject { participant; client_order_id; reason } ->
    sprintf
      "CANCEL_REJECTED participant=%s client_id=%d reason=%s"
      (Participant.to_string participant)
      (Client_order_id.to_int client_order_id)
      reason
;;

let format_events events =
  List.map events ~f:format_event |> String.concat ~sep:"\n"
;;
