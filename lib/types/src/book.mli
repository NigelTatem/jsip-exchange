(** A read-only snapshot of an order book.

    Contains the symbol, all resting price levels on each side (aggregated by
    price), and the BBO. *)

open! Core

type t =
  { symbol : Symbol_id.t
  ; bids : Level.t list
  ; asks : Level.t list
  ; bbo : Bbo.t
  }
[@@deriving sexp, bin_io]

(** [render_symbol] turns the wire id into display text. The caller supplies
    the policy: [Symbol_id.to_string] for the raw id, or a consumer's
    [Symbol_directory.render] for the human name. *)
val to_string : render_symbol:(Symbol_id.t -> string) -> t -> string
