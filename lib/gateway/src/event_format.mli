(** Human-readable formatting of exchange events.

    Renders each {!Jsip_types.Exchange_event.t} as a single line of text for
    display in the CLI client, monitor, and audit log. On a production
    exchange this would be a binary protocol like FIX; the text format here
    is for ease of debugging and interactive use. Command {i parsing} lives
    in {!Exchange_command}. *)

open! Core
open Jsip_types

(** Format an exchange event as a single line of human-readable text.

    [render_symbol] resolves the wire-level {!Symbol_id.t} to display text.
    The caller supplies the policy: [Symbol_id.to_string] for the raw id, or
    a client/monitor's [Symbol_directory.render] for the human symbol name. *)
val format_event
  :  render_symbol:(Symbol_id.t -> string)
  -> Exchange_event.t
  -> string

(** Format a list of events, one per line. See {!format_event} for
    [render_symbol]. *)
val format_events
  :  render_symbol:(Symbol_id.t -> string)
  -> Exchange_event.t list
  -> string
