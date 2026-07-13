open! Core
open Jsip_types
open Jsip_order_book

(* Running tallies of the events the engine emitted. This mix is the quickest
   check that the workload did what its config prescribed: a [book-heavy]
   preset should show accepts >> fills, a [churn] preset lots of cancels. *)
module Event_counts = struct
  type t =
    { mutable accepts : int
    ; mutable fills : int
    ; mutable cancels : int
    ; mutable rejects : int
    ; mutable market_data : int
    }

  let create () =
    { accepts = 0; fills = 0; cancels = 0; rejects = 0; market_data = 0 }
  ;;

  let observe t (event : Exchange_event.t) =
    match event with
    | Order_accept _ -> t.accepts <- t.accepts + 1
    | Fill _ -> t.fills <- t.fills + 1
    | Order_cancel _ -> t.cancels <- t.cancels + 1
    | Order_reject _ | Cancel_reject _ -> t.rejects <- t.rejects + 1
    | Best_bid_offer_update _ | Trade_report _ ->
      t.market_data <- t.market_data + 1
  ;;
end

(* Total resting orders across every book — the number that must plateau for
   the run to be at steady state. *)
let book_depth engine ~num_symbols =
  let total = ref 0 in
  for i = 0 to num_symbols - 1 do
    match Matching_engine.book engine (Symbol_id.of_int i) with
    | None -> ()
    | Some book ->
      total
      := !total + Order_book.count book Buy + Order_book.count book Sell
  done;
  !total
;;

let run
  ~preset_name
  ~(config : Workload.Config.t)
  ~seed
  ~num_actions
  ~depth_every
  ~latency
  =
  let symbols =
    List.init config.num_symbols ~f:(fun i -> Symbol_id.of_int i)
  in
  let engine = Matching_engine.create symbols in
  let generator = Workload.create config ~seed in
  let counts = Event_counts.create () in
  (* Per-call timing perturbs the profile, so it is opt-in: a [perf] run
     wants [-latency] off to see the pure engine; a latency run turns it on.
     The histogram is allocated only when needed. *)
  let hist = if latency then Some (Histogram.create ()) else None in
  let dispatch (action : Workload.Action.t) =
    match action with
    | Submit request -> Matching_engine.submit engine request
    | Cancel { participant; client_order_id } ->
      Matching_engine.cancel engine ~participant ~client_order_id
  in
  let gc_before = Gc.stat () in
  let start = Time_ns.now () in
  for action_ix = 1 to num_actions do
    let action = Workload.next generator in
    let events =
      match hist with
      | None -> dispatch action
      | Some hist ->
        let t0 = Time_ns.now () in
        let events = dispatch action in
        Histogram.add
          hist
          (Time_ns.diff (Time_ns.now ()) t0 |> Time_ns.Span.to_int_ns);
        events
    in
    List.iter events ~f:(Event_counts.observe counts);
    if depth_every > 0 && action_ix % depth_every = 0
    then
      printf
        "  [%9d actions] book depth = %d\n"
        action_ix
        (book_depth engine ~num_symbols:config.num_symbols)
  done;
  let elapsed = Time_ns.diff (Time_ns.now ()) start in
  let gc_after = Gc.stat () in
  let elapsed_s = Time_ns.Span.to_sec elapsed in
  let per_sec = Float.of_int num_actions /. elapsed_s in
  printf
    "\n=== replay: preset=%s seed=%d actions=%d ===\n"
    preset_name
    seed
    num_actions;
  printf "wall time     : %s\n" (Time_ns.Span.to_string_hum elapsed);
  printf "throughput    : %.0f actions/sec\n" per_sec;
  printf
    "events        : accept=%d fill=%d cancel=%d reject=%d market_data=%d\n"
    counts.accepts
    counts.fills
    counts.cancels
    counts.rejects
    counts.market_data;
  printf
    "final depth   : %d resting orders\n"
    (book_depth engine ~num_symbols:config.num_symbols);
  printf
    "GC            : minor_collections=%d major_collections=%d live_words=%d\n"
    (gc_after.minor_collections - gc_before.minor_collections)
    (gc_after.major_collections - gc_before.major_collections)
    gc_after.live_words;
  Option.iter hist ~f:(fun hist ->
    let ns p = Histogram.percentile hist p |> Option.value ~default:0 in
    printf
      "latency (ns)  : p50=%d p99=%d p99.9=%d max=%d\n"
      (ns 50.)
      (ns 99.)
      (ns 99.9)
      (Histogram.max_ns hist |> Option.value ~default:0);
    printf "latency dist  :\n%s" (Histogram.to_ascii hist))
;;

let preset_arg =
  Command.Arg_type.of_alist_exn
    ~list_values_in_help:true
    [ "balanced", "balanced"; "churn", "churn"; "book-heavy", "book-heavy" ]
;;

let command =
  Command.basic
    ~summary:
      "Drive the matching engine under synthetic load and report \
       throughput, event mix, book depth, and GC."
    (let%map_open.Command preset_name =
       flag
         "-preset"
         (optional_with_default "balanced" preset_arg)
         ~doc:"NAME workload preset (default balanced)"
     and seed =
       flag
         "-seed"
         (optional_with_default 0 int)
         ~doc:"INT random seed (default 0)"
     and num_actions =
       flag
         "-num-actions"
         (optional_with_default 1_000_000 int)
         ~doc:"INT number of actions to pump (default 1_000_000)"
     and depth_every =
       flag
         "-depth-every"
         (optional_with_default 0 int)
         ~doc:
           "INT print book depth every N actions to confirm steady state (0 \
            = never)"
     and latency =
       flag
         "-latency"
         no_arg
         ~doc:
           " measure per-call latency and report percentiles + histogram \
            (off by default; perturbs profiling)"
     in
     fun () ->
       match Workload.Config.of_preset_name preset_name with
       | None -> failwithf "unknown preset %s" preset_name ()
       | Some config ->
         run ~preset_name ~config ~seed ~num_actions ~depth_every ~latency)
;;
