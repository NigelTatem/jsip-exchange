(** Tests for {!Exchange_stats} snapshots, in two layers: pure dispatcher
    plumbing (per-subscriber backlog attribution, no server in the loop) and
    end-to-end snapshots through a real server via [Exchange_server.stats]
    (participant activity, book depth, and the anonymous read-only-abuser
    connection row). *)

open! Core
open! Async
open Jsip_types
open Jsip_gateway
open Jsip_test_harness

let bbo_update symbol =
  Exchange_event.Best_bid_offer_update { symbol; bbo = Bbo.empty }
;;

let print_rows dispatcher =
  print_s
    [%sexp
      (Dispatcher.subscriber_stats dispatcher
       : Exchange_stats.Subscriber.t list)]
;;

let%expect_test "subscriber backlog is labeled and shrinks as events are \
                 read"
  =
  let dispatcher =
    Dispatcher.create
      ~subscriber_pipe_budget:1024
      ~registry:(Participant_registry.create ())
      ()
  in
  let reader =
    Dispatcher.subscribe_market_data
      dispatcher
      [ Harness.aapl ]
      ~label:"market-data:test-subscriber"
  in
  Dispatcher.dispatch
    dispatcher
    (List.init 3 ~f:(fun (_ : int) -> bbo_update Harness.aapl));
  print_rows dispatcher;
  [%expect {| (((label market-data:test-subscriber) (pipe_length 3))) |}];
  let%bind (_ : [ `Ok of Exchange_event.t | `Eof ]) = Pipe.read reader in
  print_rows dispatcher;
  [%expect {| (((label market-data:test-subscriber) (pipe_length 2))) |}];
  print_s
    [%message
      "" ~events_dispatched:(Dispatcher.events_dispatched dispatcher : int)];
  [%expect {| (events_dispatched 3) |}];
  return ()
;;

(* Regression guard for the double-counting trap: one subscriber watching two
   symbols is one pipe registered in two per-symbol bags, but must appear in
   the stats exactly once, with the backlog of the single pipe. *)
let%expect_test "a multi-symbol subscriber appears in stats exactly once" =
  let dispatcher =
    Dispatcher.create
      ~subscriber_pipe_budget:1024
      ~registry:(Participant_registry.create ())
      ()
  in
  let msft = Symbol_id.of_int 1 in
  let (_ : Exchange_event.t Pipe.Reader.t) =
    Dispatcher.subscribe_market_data
      dispatcher
      [ Harness.aapl; msft ]
      ~label:"market-data:two-symbols"
  in
  Dispatcher.dispatch dispatcher [ bbo_update Harness.aapl ];
  Dispatcher.dispatch dispatcher [ bbo_update msft ];
  print_rows dispatcher;
  [%expect {| (((label market-data:two-symbols) (pipe_length 2))) |}];
  return ()
;;

let%expect_test "audit and session feeds get their own labeled rows" =
  let registry = Participant_registry.create () in
  let dispatcher =
    Dispatcher.create ~subscriber_pipe_budget:1024 ~registry ()
  in
  let (_ : Exchange_event.t Pipe.Reader.t) =
    Dispatcher.subscribe_audit dispatcher ~label:"audit:test-monitor"
  in
  let%bind (_ : Session.t) =
    Dispatcher.set_up_session
      dispatcher
      (Participant_registry.intern registry Harness.alice)
  in
  (* The BBO update reaches the audit firehose but not Alice's session; her
     row exists (she is logged in) with an empty backlog. *)
  Dispatcher.dispatch dispatcher [ bbo_update Harness.aapl ];
  print_rows dispatcher;
  [%expect
    {|
    (((label audit:test-monitor) (pipe_length 1))
     ((label session:Alice) (pipe_length 0)))
    |}];
  return ()
;;

(* The bounding contract (design doc, Phase 5): a subscriber that stops
   reading is evicted when its pipe hits the budget; a subscriber that keeps
   up is untouched. *)
let%expect_test "a subscriber at the pipe budget is evicted and counted" =
  let dispatcher =
    Dispatcher.create
      ~subscriber_pipe_budget:3
      ~registry:(Participant_registry.create ())
      ()
  in
  let never_reads =
    Dispatcher.subscribe_market_data
      dispatcher
      [ Harness.aapl ]
      ~label:"market-data:never-reads"
  in
  let keeps_up =
    Dispatcher.subscribe_market_data
      dispatcher
      [ Harness.aapl ]
      ~label:"market-data:keeps-up"
  in
  (* Three events fill both pipes exactly to the budget; the fast subscriber
     drains its pipe, the slow one doesn't. *)
  Dispatcher.dispatch
    dispatcher
    (List.init 3 ~f:(fun (_ : int) -> bbo_update Harness.aapl));
  let%bind (_ : [ `Ok of Exchange_event.t Queue.t | `Eof ]) =
    Pipe.read' keeps_up
  in
  (* The next event evicts the slow subscriber (its pipe is at budget) and is
     delivered to the fast one as usual. *)
  Dispatcher.dispatch dispatcher [ bbo_update Harness.aapl ];
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  print_rows dispatcher;
  print_s [%message "" ~evictions:(Dispatcher.evictions dispatcher : int)];
  [%expect
    {|
    (((label market-data:keeps-up) (pipe_length 1)))
    (evictions 1)
    |}];
  let%bind read_result = Pipe.read never_reads in
  let evicted_subscriber_sees =
    match read_result with
    | `Eof -> "eof after draining"
    | `Ok (_ : Exchange_event.t) -> "buffered event, then eof"
  in
  print_s [%sexp (evicted_subscriber_sees : string)];
  [%expect {| "buffered event, then eof" |}];
  return ()
;;

(* --- End-to-end snapshots through a real server --- *)

let%expect_test "stats: participant activity merges submits with resting \
                 orders"
  =
  E2e_helpers.with_server ~symbols:[ Harness.aapl ] (fun ~server ~port ->
    let%bind alice = E2e_helpers.connect_as ~port Harness.alice in
    let%bind bob = E2e_helpers.connect_as ~port Harness.bob in
    (* Alice's bid rests; Bob's smaller sell fills completely against it,
       leaving Bob with submits but nothing resting (the [`Left] case of the
       snapshot merge) and Alice with both. *)
    let%bind () =
      E2e_helpers.rpc_submit alice (Harness.buy ~price_cents:15000 ())
    in
    let%bind () =
      E2e_helpers.rpc_submit
        bob
        (Harness.sell ~price_cents:15000 ~size:40 ())
    in
    let%bind () = Scheduler.yield_until_no_jobs_remain () in
    let stats = Exchange_server.stats server in
    print_s
      [%sexp
        (stats.participants : Exchange_stats.Participant_activity.t list)];
    print_s [%sexp (stats.symbols : Exchange_stats.Symbol_depth.t list)];
    print_s [%message "" ~events_dispatched:(stats.events_dispatched : int)];
    [%expect
      {|
      [Alice] ACCEPTED id=1 0 BUY 100@$150.00 DAY
      [Bob] ACCEPTED id=2 0 SELL 40@$150.00 DAY
      [Bob] FILL fill_id=1 0 $150.00 x40 aggressor=2(Bob) SELL 1 resting=Alice(0) 0
      [Alice] FILL fill_id=1 0 $150.00 x40 aggressor=2(Bob) SELL 1 resting=Alice(0) 0
      (((participant Alice) (submits 1) (resting_orders 1))
       ((participant Bob) (submits 1) (resting_orders 0)))
      (((symbol 0) (bbo ((bid (((price 15000) (size 60)))) (ask ())))
        (bid_depth 60) (ask_depth 0)))
      (events_dispatched 6)
      |}];
    return ())
;;

let%expect_test "stats: an anonymous market-data subscriber shows as a \
                 connection with no participant"
  =
  E2e_helpers.with_server ~symbols:[ Harness.aapl ] (fun ~server ~port ->
    let%bind (_ : E2e_helpers.client) =
      E2e_helpers.connect_as ~port Harness.alice
    in
    (* A raw connection that never logs in, subscribes to market data, and
       never reads — the read-only abuser shape from the design doc. *)
    let where =
      Tcp.Where_to_connect.of_host_and_port { host = "localhost"; port }
    in
    let%bind anonymous = Rpc.Connection.client where >>| Result.ok_exn in
    let%bind _reader, (_ : Rpc.Pipe_rpc.Metadata.t) =
      Rpc.Pipe_rpc.dispatch_exn
        Rpc_protocol.market_data_rpc
        anonymous
        [ Harness.aapl ]
    in
    let%bind () = Scheduler.yield_until_no_jobs_remain () in
    let stats = Exchange_server.stats server in
    (* Peer addresses carry OS-assigned ports, so print stable projections
       rather than raw rows. *)
    let connection_participants =
      List.map stats.connections ~f:(fun connection ->
        connection.participant)
      |> List.sort ~compare:[%compare: Participant.t option]
    in
    print_s [%sexp (connection_participants : Participant.t option list)];
    let market_data_subscribers =
      List.count stats.subscribers ~f:(fun subscriber ->
        String.is_prefix subscriber.label ~prefix:"market-data:")
    in
    print_s [%message (market_data_subscribers : int)];
    [%expect
      {|
      (() (Alice))
      (market_data_subscribers 1)
      |}];
    return ())
;;

let%expect_test "session backlog counts unread pushes" =
  let session = Session.create Harness.alice in
  Session.push session (bbo_update Harness.aapl);
  Session.push session (bbo_update Harness.aapl);
  print_s [%message "" ~backlog:(Session.backlog session : int)];
  [%expect {| (backlog 2) |}];
  let%bind (_ : [ `Ok of Exchange_event.t | `Eof ]) =
    Pipe.read (Session.reader session)
  in
  print_s [%message "" ~backlog:(Session.backlog session : int)];
  [%expect {| (backlog 1) |}];
  return ()
;;
