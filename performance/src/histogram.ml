open! Core

(* Fixed linear buckets: [bucket_width_ns]-wide, covering
   [0, bucket_width_ns * num_buckets) nanoseconds. Anything larger lands in
   the top bucket, but the exact max is tracked separately so the tail is
   still reported honestly. The storage is a single [int array] allocated
   once, so recording a sample is an O(1), non-allocating array bump — cheap
   enough to sit in the replay hot loop without dominating it. *)
let bucket_width_ns = 4
let num_buckets = 16_384

type t =
  { buckets : int array
  ; mutable count : int
  ; mutable sum_ns : int
  ; mutable min_ns : int
  ; mutable max_ns : int
  }

let create () =
  { buckets = Array.create ~len:num_buckets 0
  ; count = 0
  ; sum_ns = 0
  ; min_ns = Int.max_value
  ; max_ns = Int.min_value
  }
;;

let bucket_index ns =
  let i = ns / bucket_width_ns in
  if i < 0 then 0 else if i >= num_buckets then num_buckets - 1 else i
;;

let add t ns =
  let ns = Int.max ns 0 in
  let i = bucket_index ns in
  t.buckets.(i) <- t.buckets.(i) + 1;
  t.count <- t.count + 1;
  t.sum_ns <- t.sum_ns + ns;
  if ns < t.min_ns then t.min_ns <- ns;
  if ns > t.max_ns then t.max_ns <- ns
;;

let count t = t.count
let min_ns t = if t.count = 0 then None else Some t.min_ns
let max_ns t = if t.count = 0 then None else Some t.max_ns

let mean_ns t =
  if t.count = 0
  then None
  else Some (Float.of_int t.sum_ns /. Float.of_int t.count)
;;

let percentile t p =
  if t.count = 0
  then None
  else (
    (* Smallest sample count that covers [p]% of observations. *)
    let rank = Float.iround_up_exn (p /. 100. *. Float.of_int t.count) in
    let rank = Int.max 1 (Int.min rank t.count) in
    let rec walk i seen =
      if i >= num_buckets
      then t.max_ns
      else (
        let seen = seen + t.buckets.(i) in
        if seen >= rank
        then
          (* Report the bucket's upper edge (a "<= this" reading), but never
             overstate past the exact observed max. *)
          Int.min ((i + 1) * bucket_width_ns) t.max_ns
        else walk (i + 1) seen)
    in
    Some (walk 0 0))
;;

let to_ascii ?(bar_width = 40) ?(max_rows = 16) ?(display_pct = 99.9) t =
  if t.count = 0
  then "(empty)"
  else (
    (* Latency is heavy-tailed: a handful of GC pauses or scheduler hiccups
       can be 1000x the median. Charting the whole [min, max] range would
       crush every ordinary sample into the first row, so we chart only the
       dense region up to [display_pct] and summarize the tail in one line. *)
    let lo = bucket_index t.min_ns in
    let hi =
      match percentile t display_pct with
      | None -> bucket_index t.max_ns
      | Some ns -> bucket_index ns
    in
    let span = hi - lo + 1 in
    let rows = Int.min max_rows span in
    let per_row = (span + rows - 1) / rows in
    let row_bounds r =
      let a = lo + (r * per_row) in
      a, Int.min hi (a + per_row - 1)
    in
    let row_count r =
      let a, b = row_bounds r in
      let total = ref 0 in
      for i = a to b do
        total := !total + t.buckets.(i)
      done;
      !total
    in
    let counts = Array.init rows ~f:row_count in
    let busiest = Array.fold counts ~init:1 ~f:Int.max in
    let buf = Buffer.create 256 in
    Array.iteri counts ~f:(fun r c ->
      let a, b = row_bounds r in
      let bar = c * bar_width / busiest in
      Buffer.add_string
        buf
        (sprintf
           "%7d-%7d ns | %-*s %d\n"
           (a * bucket_width_ns)
           ((b + 1) * bucket_width_ns)
           bar_width
           (String.make bar '#')
           c));
    (* Everything above the charted region, folded into a single tail line so
       the outliers are visible without distorting the bars. *)
    let charted = Array.fold counts ~init:0 ~f:( + ) in
    let tail = t.count - charted in
    if tail > 0
    then
      Buffer.add_string
        buf
        (sprintf
           "%7d+       ns | (tail) %d samples, max=%d\n"
           ((hi + 1) * bucket_width_ns)
           tail
           t.max_ns);
    Buffer.contents buf)
;;
