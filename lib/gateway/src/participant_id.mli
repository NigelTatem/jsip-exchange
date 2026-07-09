(** A server-local integer id interned from a participant's name at login.

    Ex 3's "int on the inside": the gateway keys its own tables — the
    dispatcher's [sessions], the server's [submits] — by this id rather than
    the [Participant.t] name, and resolves it back to a name at every edge
    (events, stats, human display). Ids are minted only by the participant
    registry and {b never cross the wire}, so — unlike the id types in
    [lib/types] — this one deliberately has no [bin_io]. *)

open! Core

type t = private int [@@deriving sexp, compare, equal, hash]

include Comparable.S with type t := t
include Hashable.S with type t := t

(** The underlying int — e.g. to index a dense array of names in the
    registry, or when rendering for debugging. *)
val to_int : t -> int

(** Mint an id from a raw int. Intended for the participant registry only: it
    is the single source of ids, and nothing else should manufacture one. *)
val of_int : int -> t
