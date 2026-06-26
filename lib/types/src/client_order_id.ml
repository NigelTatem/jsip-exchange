open! Core
include Int

let to_int = Fn.id
let of_int = Fn.id

module T = struct
  type t = int [@@deriving sexp, bin_io, compare, equal, hash]
end

include Comparable.Make (T)
include Hashable.Make (T)
