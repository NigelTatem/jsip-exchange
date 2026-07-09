open! Core
open Jsip_types

type t =
  { name_to_id : Participant_id.t Participant.Table.t
  ; id_to_name :
      Participant.t Dynarray.t (* index = the id's underlying int *)
  }

let create () =
  { name_to_id = Participant.Table.create ()
  ; id_to_name = Dynarray.create ()
  }
;;

let intern t name =
  match Hashtbl.find t.name_to_id name with
  | Some id -> id
  | None ->
    let id = Participant_id.of_int (Dynarray.length t.id_to_name) in
    Dynarray.add_last t.id_to_name name;
    Hashtbl.set t.name_to_id ~key:name ~data:id;
    id
;;

let id t name = Hashtbl.find t.name_to_id name
let name t id = Dynarray.get t.id_to_name (Participant_id.to_int id)
