(** Exchange server for production use and testing.

    Bundles the matching engine, market data bus, and RPC implementations
    into a single server that can be started on any port. Used by the server
    binary, the market maker binary, and integration tests. *)

open! Core
open! Async
open Jsip_types

type t

(** Start a server on the given port with the given symbol ids. [directory]
    carries the name<->id mapping served over
    {!Rpc_protocol.symbol_directory_rpc}; pass {!Symbol_directory.empty} for
    an int-only server (the tests do). The [main] binary builds the
    authoritative directory and passes both it and its ids
    ({!Symbol_directory.ids}) here. Returns the server handle; read the port
    it is actually listening on with {!port} (useful when you pass port 0 to
    get an OS-assigned port). *)
val start
  :  directory:Symbol_directory.t
  -> symbols:Symbol_id.t list
  -> port:int
  -> unit
  -> t Deferred.t

(** The port the server is listening on. *)
val port : t -> int

(** Snapshot of exchange health across the four stats families (buffer
    occupancy, participant activity, book depth, engine busyness); served to
    clients via {!Rpc_protocol.exchange_stats_rpc}. Cheap — O(resting orders
    + subscribers + connections) — so safe to poll every second. Reading a
      snapshot resets the engine's max-gap accumulator; see
      {!Exchange_stats.Engine.max_gap_since_last_snapshot}. *)
val stats : t -> Exchange_stats.t

(** Stop the server and close all connections. *)
val close : t -> unit Deferred.t

(** Wait until the server's TCP listener is closed. *)
val close_finished : t -> unit Deferred.t
