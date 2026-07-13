open! Core

(** Command-line entry point: the group of performance pre-exercises. *)
val command : Command.t

(** Latency histogram used by the [replay] driver; exposed so it can be
    exercised by expect tests. *)
module Histogram : module type of Histogram
