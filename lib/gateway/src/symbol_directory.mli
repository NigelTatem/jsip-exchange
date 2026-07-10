(** A bidirectional {!Symbol.t} name <-> {!Symbol_id.t} id map.

    Ex 4's "int on the wire" ships only the id; the directory is how a
    consumer recovers the human name. Unlike {!Participant_registry} (Ex 3),
    which is server-only and additive, this one is a fixed snapshot that
    {b crosses the wire}: the server builds the authoritative copy in [main]
    from its symbol set, serves the [(name, id)] pairs via
    {!Rpc_protocol.symbol_directory_rpc}, and each client/monitor mirrors it
    once at connect with {!of_pairs}.

    Resolution runs at the edges: name->id at parse ({!id_of_name}, when a
    human types [BUY AAPL]) and id->name at render ({!render}, when printing
    an event or book). [lib/types] stays int-only; this module is where the
    id becomes a name again. *)

open! Core
open Jsip_types

type t

(** No symbols known. Servers with no directory (the int-based test suite)
    serve this, so {!render} falls back to printing the raw id. *)
val empty : t

(** Assign symbol at position [i] the id [i], matching the matching engine's
    [create]. Used by the server's [main] to build the authoritative
    directory from its ordered symbol list. *)
val of_names : Symbol.t list -> t

(** Rebuild the mirror from the [(name, id)] pairs served over the wire.
    Raises if a name or id is duplicated. *)
val of_pairs : (Symbol.t * Symbol_id.t) list -> t

(** The [(name, id)] pairs, for the directory RPC to ship to consumers. *)
val to_pairs : t -> (Symbol.t * Symbol_id.t) list

(** All ids in numeric order — the order {!Matching_engine.create} indexes
    its book array by. *)
val ids : t -> Symbol_id.t list

(** Resolve a human name to its id at parse time. [None] if the name is not a
    known symbol (reject it — don't invent an id). *)
val id_of_name : t -> Symbol.t -> Symbol_id.t option

(** Resolve an id back to its name. [None] if the id is not in the directory. *)
val name_of_id : t -> Symbol_id.t -> Symbol.t option

(** Render an id for display: its name if known, else the raw id string. The
    fallback keeps an out-of-directory id printable rather than raising at a
    render site. *)
val render : t -> Symbol_id.t -> string
