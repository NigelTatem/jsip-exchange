(** Tests for the dashboard's pure controller: window trimming, the
    high-water mark, rate computation (including the restart discontinuity),
    ranking, and staleness — all with hand-built samples, no server or Bonsai
    in the loop. *)

open! Core
open Jsip_types
open Jsip_test_harness
module Controller = Jsip_dashboard_controller.Controller
module Response = Jsip_dashboard_protocol.Recent_samples.Response

let at seconds = Time_ns.of_span_since_epoch (Time_ns.Span.of_sec seconds)

let sample
  ?(participants = [])
  ?(connections = [])
  ?(max_gap_ms = 0.)
  ?(evictions = 0)
  ~at_sec
  ~events
  ()
  : Exchange_stats.t
  =
  { taken_at = at at_sec
  ; subscribers = []
  ; connections
  ; participants
  ; symbols = []
  ; engine =
      { max_gap_since_last_snapshot = Time_ns.Span.of_ms max_gap_ms
      ; request_queue_length = 0
      }
  ; events_dispatched = events
  ; evictions
  }
;;

let feed ?(exchange_connected = true) controller samples =
  Controller.feed_response
    controller
    { Response.samples; exchange_connected }
;;

let%expect_test "window trims to window_size and tracks the high-water mark" =
  let samples =
    List.init 130 ~f:(fun i ->
      sample ~at_sec:(Float.of_int i) ~events:(i * 10) ())
  in
  let controller = feed (Controller.create ()) samples in
  let display = Controller.display controller ~now:(at 129.) in
  print_s
    [%message
      ""
        ~sample_count:(display.sample_count : int)
        ~window_size:(Controller.window_size : int)
        ~last_seen_at:(Controller.last_seen_at controller : Time_ns.t option)];
  [%expect
    {|
    ((sample_count 120) (window_size 120)
     (last_seen_at ((1970-01-01 00:02:09.000000000Z))))
    |}]
;;

let%expect_test "events/sec rates, with a restart rendered as a gap" =
  (* 0 -> 1000 over 1s, 1000 -> 1500 over 1s, then the counter goes BACKWARD
     (exchange restart): that interval must be [None], not a negative rate. *)
  let controller =
    feed
      (Controller.create ())
      [ sample ~at_sec:0. ~events:0 ()
      ; sample ~at_sec:1. ~events:1000 ()
      ; sample ~at_sec:2. ~events:1500 ()
      ; sample ~at_sec:3. ~events:100 ()
      ]
  in
  let display = Controller.display controller ~now:(at 3.) in
  print_s [%sexp (display.events_per_sec_series : float option list)];
  [%expect {| ((1000) (500) ()) |}]
;;

let%expect_test "participant rates average over the window; newcomers and \
                 restarts get no rate; busiest first"
  =
  let activity participant submits resting
    : Exchange_stats.Participant_activity.t
    =
    { participant; submits; resting_orders = resting }
  in
  let controller =
    feed
      (Controller.create ())
      [ sample
          ~at_sec:0.
          ~events:0
          ~participants:[ activity Harness.alice 0 0 ]
          ()
      ; sample
          ~at_sec:10.
          ~events:0
          ~participants:
            [ activity Harness.alice 20 3
              (* Bob appears only in the newest sample: nothing to diff
                 against, so no rate — but his resting orders still show. *)
            ; activity Harness.bob 5 1
            ]
          ()
      ]
  in
  let display = Controller.display controller ~now:(at 10.) in
  print_s
    [%sexp
      (display.participants : Controller.Display.Participant_row.t list)];
  [%expect
    {|
    (((participant Alice) (submits_per_sec (2)) (resting_orders 3))
     ((participant Bob) (submits_per_sec ()) (resting_orders 1)))
    |}]
;;

let%expect_test "participant rate measures from the most recent restart, \
                 not across it"
  =
  (* The window still contains a pre-restart sample where Alice's counter was
     huge. Her rate must be computed from history since the reset — (15 - 5)
     / 10s = 1.0/s — not blanked for as long as the stale sample stays in the
     window. *)
  let activity submits : Exchange_stats.Participant_activity.t =
    { participant = Harness.alice; submits; resting_orders = 0 }
  in
  let controller =
    feed
      (Controller.create ())
      [ sample ~at_sec:0. ~events:0 ~participants:[ activity 20_000 ] ()
      ; sample ~at_sec:10. ~events:0 ~participants:[ activity 5 ] ()
      ; sample ~at_sec:20. ~events:0 ~participants:[ activity 15 ] ()
      ]
  in
  let display = Controller.display controller ~now:(at 20.) in
  print_s
    [%sexp
      (display.participants : Controller.Display.Participant_row.t list)];
  [%expect
    {| (((participant Alice) (submits_per_sec (1)) (resting_orders 0))) |}]
;;

let%expect_test "connections sort worst-first by bytes_to_write" =
  let connection peer participant bytes : Exchange_stats.Connection.t =
    { peer
    ; participant = Option.map participant ~f:Participant.of_string
    ; bytes_to_write = bytes
    }
  in
  let controller =
    feed
      (Controller.create ())
      [ sample
          ~at_sec:0.
          ~events:0
          ~connections:
            [ connection "127.0.0.1:1001" (Some "Alice") 0
            ; connection "127.0.0.1:1002" None 50_000
            ; connection "127.0.0.1:1003" (Some "Bob") 12
            ]
          ()
      ]
  in
  let display = Controller.display controller ~now:(at 0.) in
  print_s
    [%sexp (display.connections : Controller.Display.Connection_row.t list)];
  [%expect
    {|
    (((peer 127.0.0.1:1002) (participant ()) (bytes_to_write 50000))
     ((peer 127.0.0.1:1003) (participant (Bob)) (bytes_to_write 12))
     ((peer 127.0.0.1:1001) (participant (Alice)) (bytes_to_write 0)))
    |}]
;;

let%expect_test "staleness and reachability flags" =
  let controller = Controller.create () in
  let display = Controller.display controller ~now:(at 0.) in
  print_s
    [%message
      "before any sample"
        ~staleness:(display.staleness : Time_ns.Span.t option)
        ~dashboard_reachable:(display.dashboard_reachable : bool)];
  [%expect
    {| ("before any sample" (staleness ()) (dashboard_reachable false)) |}];
  let controller = feed controller [ sample ~at_sec:0. ~events:0 () ] in
  let display = Controller.display controller ~now:(at 5.) in
  print_s
    [%message
      "fed, then 5s pass"
        ~staleness:(display.staleness : Time_ns.Span.t option)
        ~dashboard_reachable:(display.dashboard_reachable : bool)
        ~exchange_connected:(display.exchange_connected : bool)];
  [%expect
    {|
    ("fed, then 5s pass" (staleness (5s)) (dashboard_reachable true)
     (exchange_connected true))
    |}];
  let controller = Controller.feed_poll_error controller in
  let display = Controller.display controller ~now:(at 5.) in
  print_s
    [%message
      "poll error keeps history"
        ~sample_count:(display.sample_count : int)
        ~dashboard_reachable:(display.dashboard_reachable : bool)];
  [%expect
    {|
    ("poll error keeps history" (sample_count 1) (dashboard_reachable false))
    |}]
;;
