open! Core

module List_seq = struct
  type t = int list ref

  let create () = ref []

  let set t ~key ~data =
    let len = List.length !t in
    if key < 0 || key > len
    then
      raise_s
        [%message "List_seq.set: key out of range" (key : int) (len : int)]
    else if key = len
    then t := !t @ [ data ]
    else t := List.mapi !t ~f:(fun i x -> if i = key then data else x)
  ;;

  let get t key = List.nth !t key
end

module Dynarray_seq = struct
  (* TODO: replace the definition of type t and the implementations of
     create, set, and get *)
  type t = int Dynarray.t

  let create () = Dynarray.create ()

  let set t ~key ~data =
    let len = Dynarray.length t in
    if key < 0 || key > len
    then
      raise_s
        [%message
          "Dynarray_seq.set: key out of range" (key : int) (len : int)]
    else if key = len
    then Dynarray.add_last t data
    else Dynarray.set t key data
  ;;

  let get t key =
    if key < 0 || key >= Dynarray.length t
    then None
    else Some (Dynarray.get t key)
  ;;
end
