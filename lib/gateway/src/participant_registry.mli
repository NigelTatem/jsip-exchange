(** The server's authoritative name <-> id map for participants.

    Interns each [Participant.t] name to a small [Participant_id.t] the first
    time it logs in, and hands back the {e same} id on every reconnect. One
    registry is created in [Exchange_server.start] and shared by every
    connection, so an id means the same participant to everyone who sees it —
    both sides of a [Fill], say.

    It is {b additive}: an id stays valid for the whole run and is never
    removed. That is a different lifetime from the dispatcher's [sessions]
    table, which tracks who is {e currently connected} and is pruned on
    disconnect. The id never leaves the gateway; callers resolve it back to a
    name with [name] at every edge (events, stats, display). *)

open! Core
open Jsip_types

type t

val create : unit -> t

(** Return [name]'s id, minting a fresh one if this is the first time we've
    seen it. Idempotent: the same name always maps to the same id. Call this
    at login. *)
val intern : t -> Participant.t -> Participant_id.t

(** Look up an already-interned name's id without minting. [None] if the name
    was never interned. Use this on the routing path — resolving the
    participant named on an event to its session — where a miss should be
    skipped, not turned into a phantom registration. *)
val id : t -> Participant.t -> Participant_id.t option

(** Resolve an id back to its name. Total: a [Participant_id.t] can only have
    come from [intern] on this registry, so it always indexes a name. *)
val name : t -> Participant_id.t -> Participant.t
