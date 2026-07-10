open! Core
open Jsip_types

type t =
  | Submit of Order.Request.t
  | Book of Symbol_id.t
  | Subscribe of Symbol_id.t
  | Cancel of Client_order_id.t
  | Stats

(** Parse one line of client input into a typed command.

    A symbol token is resolved through [directory]: a human types the name
    ([BOOK AAPL]) and it becomes the id on the wire. When the token is not a
    known name, a bare int id is accepted as a fallback — so
    {!Symbol_directory.empty} yields int-only parsing. An unknown symbol name
    is rejected. Range-checking the id is the server's job, not the parser's. *)
val parse
  :  ?default_participant:Participant.t
  -> directory:Symbol_directory.t
  -> string
  -> t Or_error.t
