(** A fixed-bucket latency histogram for the [replay] driver (Part 4,
    Exercise 6).

    Records per-call latencies (in nanoseconds) in O(1) space and time — a
    single pre-allocated [int array] — so it can sit in the replay hot loop
    without allocating per sample the way collecting every raw sample into a
    growing array would. Percentiles are derived from the bucket counts;
    [min_ns]/[max_ns]/[mean_ns] are tracked exactly.

    {2 Example}

    {[
      let h = Histogram.create () in
      List.iter [ 40; 55; 60; 900 ] ~f:(Histogram.add h);
      Histogram.percentile h 50. (* the median bucket's upper edge *)
    ]} *)

open! Core

type t

val create : unit -> t

(** Record one latency sample, in nanoseconds. Negative inputs are clamped to
    0. Samples beyond the tracked range land in the top bucket, but still
    update the exact [max_ns]. *)
val add : t -> int -> unit

(** Number of samples recorded. *)
val count : t -> int

(** Exact minimum / maximum sample, or [None] if empty. *)
val min_ns : t -> int option

val max_ns : t -> int option

(** Exact arithmetic mean, or [None] if empty. *)
val mean_ns : t -> float option

(** [percentile t p] is the [p]th-percentile latency ([p] in [0., 100.]),
    reported as the covering bucket's upper edge (a "at most this many ns"
    reading) capped at the exact observed max. [None] if empty. Bucket
    resolution bounds the precision; [max_ns] is exact if you need the true
    tail. *)
val percentile : t -> float -> int option

(** A little bar chart of the latency distribution, scaled to the busiest
    row. Because latency is heavy-tailed, only the dense region up to
    [display_pct] (default 99.9) is charted; everything above is folded into
    a single "(tail)" line reporting the count and exact max. No samples
    renders as ["(empty)"]. *)
val to_ascii
  :  ?bar_width:int
  -> ?max_rows:int
  -> ?display_pct:float
  -> t
  -> string
