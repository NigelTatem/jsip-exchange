(** Human-readable formatting of exchange events.

    Renders each {!Jsip_types.Exchange_event.t} as a single line of text for
    display in the CLI client, monitor, and audit log. On a production
    exchange this would be a binary protocol like FIX; the text format here
    is for ease of debugging and interactive use. Command {i parsing} lives
    in {!Exchange_command}. *)

open! Core
open Jsip_types

(** Format an exchange event as a single line of human-readable text. *)
val format_event : Exchange_event.t -> string

(** Format a list of events, one per line. *)
val format_events : Exchange_event.t list -> string
