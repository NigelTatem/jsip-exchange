open! Core
open Jsip_types

type t =
  { name_of_id : Symbol.t Symbol_id.Map.t
  ; id_of_name : Symbol_id.t Symbol.Map.t
  }

let empty =
  { name_of_id = Symbol_id.Map.empty; id_of_name = Symbol.Map.empty }
;;

let of_pairs pairs =
  { name_of_id =
      List.map pairs ~f:(fun (name, id) -> id, name)
      |> Symbol_id.Map.of_alist_exn
  ; id_of_name = Symbol.Map.of_alist_exn pairs
  }
;;

let of_names names =
  List.mapi names ~f:(fun i name -> name, Symbol_id.of_int i) |> of_pairs
;;

(* Sorted by name; the RPC payload order is irrelevant since the consumer
   rebuilds both maps from it. *)
let to_pairs t = Map.to_alist t.id_of_name

(* Ids in numeric order (0, 1, 2, ...) — the order the engine's book array
   expects. *)
let ids t = Map.keys t.name_of_id
let id_of_name t name = Map.find t.id_of_name name
let name_of_id t id = Map.find t.name_of_id id

let render t id =
  match Map.find t.name_of_id id with
  | Some name -> Symbol.to_string name
  | None -> Symbol_id.to_string id
;;
