open! Core
open Jsip_types
module Response = Jsip_dashboard_protocol.Recent_samples.Response

module Display = struct
  module Connection_row = struct
    type t =
      { peer : string
      ; participant : string option
      ; bytes_to_write : int
      }
    [@@deriving sexp_of, compare, equal]
  end

  module Participant_row = struct
    type t =
      { participant : Participant.t
      ; submits_per_sec : float option
      ; resting_orders : int
      }
    [@@deriving sexp_of, compare, equal]
  end

  module Symbol_row = struct
    type t =
      { symbol : Symbol_id.t
      ; bid : string
      ; ask : string
      ; bid_depth : int
      ; ask_depth : int
      }
    [@@deriving sexp_of, compare, equal]
  end

  type t =
    { sample_count : int
    ; staleness : Time_ns.Span.t option
    ; exchange_connected : bool
    ; dashboard_reachable : bool
    ; connections : Connection_row.t list
    ; participants : Participant_row.t list
    ; symbols : Symbol_row.t list
    ; events_per_sec_series : float option list
    ; max_gap_ms_series : float list
    ; request_queue_series : int list
    ; evictions : int
    }
  [@@deriving sexp_of, equal]
end

let window_size = 120

type t =
  { samples : Exchange_stats.t list (* oldest -> newest, <= window_size *)
  ; exchange_connected : bool
  ; dashboard_reachable : bool
  }
[@@deriving sexp_of, equal]

let create () =
  { samples = []; exchange_connected = false; dashboard_reachable = false }
;;

let last_seen_at t =
  List.last t.samples
  |> Option.map ~f:(fun (sample : Exchange_stats.t) -> sample.taken_at)
;;

let feed_response t (response : Response.t) =
  let samples = t.samples @ response.samples in
  let overflow = List.length samples - window_size in
  { samples = (if overflow > 0 then List.drop samples overflow else samples)
  ; exchange_connected = response.exchange_connected
  ; dashboard_reachable = true
  }
;;

let feed_poll_error t = { t with dashboard_reachable = false }

(* Per-poll-interval rate of a cumulative counter. A negative delta means the
   counter restarted with the exchange; that interval is a [None]
   discontinuity, never a negative rate. *)
let per_interval_rates samples ~counter =
  match samples with
  | [] | [ _ ] -> []
  | _ :: successors ->
    List.map2_exn
      (List.drop_last_exn samples)
      successors
      ~f:(fun (prev : Exchange_stats.t) (next : Exchange_stats.t) ->
        let seconds =
          Time_ns.diff next.taken_at prev.taken_at |> Time_ns.Span.to_sec
        in
        let delta = counter next - counter prev in
        if Float.( <= ) seconds 0. || delta < 0
        then None
        else Some (Float.of_int delta /. seconds))
;;

let connection_rows (newest : Exchange_stats.t) =
  List.map newest.connections ~f:(fun connection ->
    { Display.Connection_row.peer = connection.peer
    ; participant =
        Option.map connection.participant ~f:Participant.to_string
    ; bytes_to_write = connection.bytes_to_write
    })
  |> List.sort ~compare:(fun a b ->
    match Int.compare b.bytes_to_write a.bytes_to_write with
    | 0 -> String.compare a.peer b.peer
    | order -> order)
;;

let submits_of (sample : Exchange_stats.t) participant =
  List.find_map
    sample.participants
    ~f:(fun (row : Exchange_stats.Participant_activity.t) ->
      match Participant.equal row.participant participant with
      | true -> Some (sample.taken_at, row.submits)
      | false -> None)
;;

(* The base for a participant's window rate: the oldest sample reachable from
   the newest without the cumulative counter moving backward — i.e. only
   history since the most recent exchange restart. Diffing across a restart
   would give a negative delta and blank the rate for as long as pre-restart
   samples stay in the window (~2 minutes). *)
let rate_base samples_newest_first participant =
  let rec walk samples ~base =
    match samples with
    | [] -> base
    | (sample : Exchange_stats.t) :: older ->
      (match submits_of sample participant with
       | None -> walk older ~base
       | Some (taken_at, submits) ->
         (match base with
          | Some (_, base_submits) when submits > base_submits ->
            (* The counter was larger further in the past: that's the restart
               boundary — stop here. *)
            base
          | Some _ | None -> walk older ~base:(Some (taken_at, submits))))
  in
  walk samples_newest_first ~base:None
;;

(* Window-averaged submit rate per participant, measured from the most recent
   counter reset (see [rate_base]). [None] when there is only one usable
   sample to date. *)
let participant_rows (samples : Exchange_stats.t list) =
  match List.last samples with
  | None -> []
  | Some newest ->
    let newest_first = List.rev samples in
    List.map
      newest.participants
      ~f:(fun (row : Exchange_stats.Participant_activity.t) ->
        let submits_per_sec =
          match rate_base newest_first row.participant with
          | None -> None
          | Some (base_at, base_submits) ->
            let seconds =
              Time_ns.diff newest.taken_at base_at |> Time_ns.Span.to_sec
            in
            let delta = row.submits - base_submits in
            if Float.( <= ) seconds 0. || delta < 0
            then None
            else Some (Float.of_int delta /. seconds)
        in
        { Display.Participant_row.participant = row.participant
        ; submits_per_sec
        ; resting_orders = row.resting_orders
        })
    |> List.sort ~compare:(fun a b ->
      let rate (row : Display.Participant_row.t) =
        Option.value row.submits_per_sec ~default:(-1.)
      in
      match Float.compare (rate b) (rate a) with
      | 0 -> Participant.compare a.participant b.participant
      | order -> order)
;;

let symbol_rows (newest : Exchange_stats.t) =
  List.map newest.symbols ~f:(fun row ->
    { Display.Symbol_row.symbol = row.symbol
    ; bid = Level.opt_to_string row.bbo.bid
    ; ask = Level.opt_to_string row.bbo.ask
    ; bid_depth = Size.to_int row.bid_depth
    ; ask_depth = Size.to_int row.ask_depth
    })
;;

let display t ~now : Display.t =
  let newest = List.last t.samples in
  { sample_count = List.length t.samples
  ; staleness =
      Option.map newest ~f:(fun (sample : Exchange_stats.t) ->
        Time_ns.diff now sample.taken_at)
  ; exchange_connected = t.exchange_connected
  ; dashboard_reachable = t.dashboard_reachable
  ; connections = Option.value_map newest ~default:[] ~f:connection_rows
  ; participants = participant_rows t.samples
  ; symbols = Option.value_map newest ~default:[] ~f:symbol_rows
  ; events_per_sec_series =
      per_interval_rates t.samples ~counter:(fun sample ->
        sample.events_dispatched)
  ; max_gap_ms_series =
      List.map t.samples ~f:(fun sample ->
        Time_ns.Span.to_ms sample.engine.max_gap_since_last_snapshot)
  ; request_queue_series =
      List.map t.samples ~f:(fun sample ->
        sample.engine.request_queue_length)
  ; evictions =
      Option.value_map
        newest
        ~default:0
        ~f:(fun (sample : Exchange_stats.t) -> sample.evictions)
  }
;;
