open! Core

type t = int [@@deriving sexp, bin_io, compare, equal, hash]

include Comparable.S with type t := t

val zero : t
val to_int : t -> int
val of_int : int -> t
val ( - ) : t -> t -> t
val ( + ) : t -> t -> t
val ( * ) : t -> int -> t
