open! Core

module Map_int = struct
  (* TODO: replace the definition of type t and the implementations of
     create, set, and get *)
  type t = { mutable map : int Int.Map.t }

  let create () = { map = Int.Map.empty }
  let set t ~key ~data = t.map <- Map.set t.map ~key ~data
  let get t key = Map.find t.map key
end

module Hashtable_int = struct
  type t = int Int.Table.t

  let create () = Int.Table.create ()
  let set = Hashtbl.set
  let get = Hashtbl.find
end

module Map_string = struct
  (* TODO: replace the definition of type t and the implementations of
     create, set, and get *)
  type t = { mutable map : int String.Map.t }

  let create () = { map = String.Map.empty }
  let set t ~key ~data = t.map <- Map.set t.map ~key ~data
  let get t key = Map.find t.map key
end

module Hashtable_string = struct
  (* TODO: replace the definition of type t and the implementations of
     create, set, and get *)
  type t = int String.Table.t

  let create () = String.Table.create ()
  let set = Hashtbl.set
  let get = Hashtbl.find
end

module Fat_record = struct
  module T = struct
    type t =
      { a : int
      ; b : string
      ; c : float
      ; d : int
      ; e : string
      ; f : bool
      ; g : int
      }
    [@@deriving compare, hash, sexp]
  end

  include T
  include Comparable.Make (T)
  include Hashable.Make (T)

  let of_index i =
    { a = i
    ; b = Int.to_string i
    ; c = Float.of_int i
    ; d = i * 2
    ; e = sprintf "key-%d" i
    ; f = Int.equal (i land 1) 0
    ; g = i * i
    }
  ;;
end

module Map_record = struct
  type t = { mutable map : int Fat_record.Map.t }

  let create () = { map = Fat_record.Map.empty }
  let set t ~key ~data = t.map <- Map.set t.map ~key ~data
  let get t key = Map.find t.map key
end

module Hashtable_record = struct
  (* TODO: replace the definition of type t and the implementations of
     create, set, and get *)
  type t = int Fat_record.Table.t

  let create () = Fat_record.Table.create ()
  let set = Hashtbl.set
  let get = Hashtbl.find
end
