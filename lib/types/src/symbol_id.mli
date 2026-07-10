(** A compact integer id for a trading symbol, carried on the wire in place
    of the {!Symbol.t} name.

    Ex 4's "int on the wire": the order, book-query, market-data, and
    event-stream RPCs carry this instead of a symbol string, shrinking every
    message. Unlike [Participant_id] in the gateway, it {b does} cross the
    wire — hence [bin_io]. The server assigns ids (symbol [i] -> id [i]) and
    publishes the name<->id pairs through the symbol-directory RPC; a
    consumer resolves a name for display via that directory. An id arriving
    from a client is untrusted and must be range-checked before use. *)

open! Core

type t = private int [@@deriving sexp, bin_io, compare, equal, hash, string]

include Comparable.S with type t := t
include Hashable.S with type t := t

(** The underlying int — e.g. to index the engine's book array, or to build
    the directory. *)
val to_int : t -> int

(** Build an id from a raw int. Does {e not} range-check: whoever takes an id
    off the wire must validate it against the known symbol set (see the
    matching engine's bounds-checked lookup). *)
val of_int : int -> t
