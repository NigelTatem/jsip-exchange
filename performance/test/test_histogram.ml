open! Core
module Histogram = Jsip_exchange_perf_lib.Histogram

let show h =
  let int_opt = Option.value_map ~default:"-" ~f:Int.to_string in
  printf
    "count=%d min=%s max=%s mean=%s\n"
    (Histogram.count h)
    (int_opt (Histogram.min_ns h))
    (int_opt (Histogram.max_ns h))
    (Option.value_map (Histogram.mean_ns h) ~default:"-" ~f:(sprintf "%.1f"));
  let pct p = int_opt (Histogram.percentile h p) in
  printf "p50=%s p90=%s p99=%s\n" (pct 50.) (pct 90.) (pct 99.)
;;

let%expect_test "empty histogram" =
  let h = Histogram.create () in
  show h;
  printf "ascii: %s\n" (Histogram.to_ascii h);
  [%expect
    {|
    count=0 min=- max=- mean=-
    p50=- p90=- p99=-
    ascii: (empty)
    |}]
;;

let%expect_test "uniform ramp gives distinct percentiles" =
  let h = Histogram.create () in
  (* 100 samples uniformly spread over [40, 139] ns: p50/p90/p99 should climb
     apart, unlike a tiny sample where the high percentiles all pin to max. *)
  List.iter (List.init 100 ~f:(fun i -> 40 + i)) ~f:(Histogram.add h);
  show h;
  [%expect
    {|
    count=100 min=40 max=139 mean=89.5
    p50=92 p90=132 p99=139
    |}]
;;

let%expect_test "percentiles ignore bucket, max is exact" =
  let h = Histogram.create () in
  (* 99 fast samples and 1 very slow one: p99 stays fast, max catches the
     outlier. *)
  for _ = 1 to 99 do
    Histogram.add h 50
  done;
  Histogram.add h 20_000;
  show h;
  [%expect
    {|
    count=100 min=50 max=20000 mean=249.5
    p50=52 p90=52 p99=52
    |}]
;;

let%expect_test "ascii bar chart" =
  let h = Histogram.create () in
  List.iter [ 10; 12; 12; 20; 20; 20; 40 ] ~f:(Histogram.add h);
  printf "%s" (Histogram.to_ascii h ~bar_width:20);
  [%expect
    {|
     8-     12 ns | ######               1
    12-     16 ns | #############        2
    16-     20 ns |                      0
    20-     24 ns | #################### 3
    24-     28 ns |                      0
    28-     32 ns |                      0
    32-     36 ns |                      0
    36-     40 ns |                      0
    40-     44 ns | ######               1
    |}]
;;
