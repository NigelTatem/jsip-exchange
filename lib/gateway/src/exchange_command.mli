open! Core
open Jsip_types

type t =
  | Submit of Order.Request.t
  | Book of Symbol.t
  | Subscribe of Symbol.t
  | Cancel of Client_order_id.t

val parse : ?default_participant:Participant.t -> string -> t Or_error.t
