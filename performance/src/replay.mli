(** The [replay] driver: pumps actions from a {!Workload} generator straight
    into a {!Jsip_order_book.Matching_engine} in a plain synchronous loop —
    no Async, no RPC, no pipes — so a profiler sees only the engine.

    It reports throughput, the event mix it actually observed (the fastest
    sanity check that the workload behaved as its config prescribes),
    periodic book depth (to confirm the book reached steady state), and GC
    stats. *)

open! Core

val command : Command.t
