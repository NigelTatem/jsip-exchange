(** A fill (execution) produced by the matching engine when two orders trade.

    Every fill involves exactly two sides: the "aggressor" (the incoming
    order that caused the match) and the "resting" order (which was already
    on the book). Both sides see the fill, but from their own perspective.

    A production exchange fill would carry additional metadata: liquidity
    flags, regulatory indicators, fee codes, timestamps, etc. *)

type t =
  { fill_id : int
  (** Unique fill identifier, assigned sequentially by the matching engine. *)
  ; symbol : Symbol_id.t
  ; price : Price.t (** The price at which the trade occurred. *)
  ; size : Size.t (** The number of shares/units traded. *)
  ; aggressor_order_id : Order_id.t
  ; aggressor_participant : Participant.t
  ; aggressor_client_order_id : Client_order_id.t
  ; aggressor_side : Side.t
  ; resting_order_id : Order_id.t
  ; resting_participant : Participant.t
  ; resting_client_order_id : Client_order_id.t
  }
[@@deriving sexp, bin_io]

(** [render_symbol] turns the wire id into display text. [lib/types] is
    name-agnostic — it never learns what a directory is — so the caller
    supplies the policy: pass [Symbol_id.to_string] for the raw id, or a
    consumer's [Symbol_directory.render] for the human name. *)
val to_string : render_symbol:(Symbol_id.t -> string) -> t -> string

(** {2 Convenience accessors} *)

(** The total notional value of the fill in cents (price * size). *)
val notional_cents : t -> int

(** As {!to_string}, the caller supplies [render_symbol]. *)
val to_participant_view
  :  render_symbol:(Symbol_id.t -> string)
  -> t
  -> Participant.t
  -> string option
