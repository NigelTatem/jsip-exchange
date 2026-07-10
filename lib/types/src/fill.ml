open! Core

type t =
  { fill_id : int
  ; symbol : Symbol_id.t
  ; price : Price.t
  ; size : Size.t
  ; aggressor_order_id : Order_id.t
  ; aggressor_participant : Participant.t
  ; aggressor_client_order_id : Client_order_id.t
  ; aggressor_side : Side.t
  ; resting_order_id : Order_id.t
  ; resting_participant : Participant.t
  ; resting_client_order_id : Client_order_id.t
  }
[@@deriving sexp, bin_io]

let to_string
  ~render_symbol
  ({ fill_id
   ; symbol
   ; price
   ; size
   ; aggressor_order_id
   ; aggressor_participant
   ; aggressor_side
   ; resting_order_id
   ; resting_participant
   ; aggressor_client_order_id
   ; resting_client_order_id
   } :
    t)
  =
  sprintf
    "fill_id=%d %s %s x%d aggressor=%s(%s) %s %s resting=%s(%d) %d"
    fill_id
    (render_symbol symbol)
    (Price.to_string_dollar price)
    (Size.to_int size)
    (Order_id.to_string aggressor_order_id)
    (Participant.to_string aggressor_participant)
    (Side.to_string aggressor_side)
    (Order_id.to_string resting_order_id)
    (Participant.to_string resting_participant)
    (Client_order_id.to_int aggressor_client_order_id)
    (Client_order_id.to_int resting_client_order_id)
;;

let notional_cents t = Price.to_int_cents t.price * Size.to_int t.size

let to_participant_view ~render_symbol (t : t) (participant : Participant.t)
  : string option
  =
  let symbol = render_symbol t.symbol in
  if Participant.equal t.resting_participant participant
  then Some [%string "You sold %{t.size#Size} %{symbol} at %{t.price#Price}"]
  else if Participant.equal t.aggressor_participant participant
  then
    Some [%string "You bought %{t.size#Size} %{symbol} at %{t.price#Price}"]
  else None
;;
