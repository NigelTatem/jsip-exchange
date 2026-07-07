(* Pure Vdom views over {!Controller.Display}. Panes render the display
   projection and nothing else — they never see raw samples, mirroring
   [app/monitor]'s render layer. *)

open! Core
open! Bonsai_web
module Display = Jsip_dashboard_controller.Controller.Display

module Fmt = struct
  (* Float formatting needs printf-style precision, which [%string] can't
     express. *)
  let bytes b =
    if b < 1024
    then [%string "%{b#Int} B"]
    else if b < 1024 * 1024
    then Printf.sprintf "%.1f KB" (Float.of_int b /. 1024.)
    else Printf.sprintf "%.1f MB" (Float.of_int b /. (1024. *. 1024.))
  ;;

  let rate = function
    | None -> "—"
    | Some rate -> Printf.sprintf "%.1f /s" rate
  ;;

  let ms value = Printf.sprintf "%.1f ms" value

  let staleness = function
    | None -> "no data"
    | Some span -> Printf.sprintf "%.1fs ago" (Time_ns.Span.to_sec span)
  ;;
end

module Spark = struct
  (* One thin bar per sample, self-scaled to the window's max so the shape
     (flat / climbing / spiking) reads at a glance. [None] values are
     discontinuities (counter resets) and render as quiet stubs with their
     own tooltip — a gap must not look like zero. *)
  let view ?(height = 40) values =
    let max_value =
      List.filter_map values ~f:fst
      |> List.max_elt ~compare:Float.compare
      |> Option.value ~default:0.
      |> Float.max 1e-9
    in
    let bars =
      List.map values ~f:(fun (value, tooltip) ->
        match value with
        | None -> {%html|<div %{Styles.spark_gap} title=%{tooltip}></div>|}
        | Some value ->
          let pct =
            Float.clamp_exn (value /. max_value *. 100.) ~min:2. ~max:100.
          in
          {%html|<div %{Styles.spark_bar ~pct} title=%{tooltip}></div>|})
    in
    {%html|<div %{Styles.spark_row ~height}>*{bars}</div>|}
  ;;
end

module Panel = struct
  let view ~title children =
    {%html|
      <section %{Styles.panel}>
        <h2 %{Styles.panel_title}>#{title}</h2>
        *{children}
      </section>
    |}
  ;;
end

module Stat = struct
  let view ?(warn = false) ~label ~value () =
    let value_style =
      if warn then Styles.stat_value_warn else Styles.stat_value
    in
    {%html|
      <div %{Styles.stat}>
        <div %{Styles.stat_label}>#{label}</div>
        <div %{value_style}>#{value}</div>
      </div>
    |}
  ;;
end

module Badge = struct
  (* Status is never color-alone: the dot carries urgency, the text says what
     it means. *)
  let view ~ok ~ok_text ~bad_text () =
    let color, text =
      if ok then "var(--color-ok)", ok_text else "var(--color-bad)", bad_text
    in
    {%html|<span %{Styles.badge}><span %{Styles.dot color}></span>#{text}</span>|}
  ;;
end

let empty_row message = {%html|<div %{Styles.empty}>#{message}</div>|}

let header (display : Display.t) =
  let window_note =
    [%string
      "%{display.sample_count#Int} samples · ~2 min window · newest \
       %{Fmt.staleness display.staleness}"]
  in
  {%html|
    <header %{Styles.header}>
      <h1 %{Styles.title}>JSIP Exchange · Operations</h1>
      <span %{Styles.quiet}>#{window_note}</span>
      <span %{Styles.header_spacer}></span>
      <Badge.view
        ~ok:%{display.exchange_connected}
        ~ok_text:%{"exchange live"}
        ~bad_text:%{"exchange down"} />
      <Badge.view
        ~ok:%{display.dashboard_reachable}
        ~ok_text:%{"dashboard link ok"}
        ~bad_text:%{"dashboard unreachable"} />
    </header>
  |}
;;

let connections_pane (display : Display.t) =
  let rows =
    List.map display.connections ~f:(fun row ->
      let participant =
        match row.participant with
        | Some name -> {%html|<span>#{name}</span>|}
        | None -> {%html|<span %{Styles.muted}>anonymous</span>|}
      in
      {%html|
        <tr>
          <td %{Styles.td_mono}>#{row.peer}</td>
          <td %{Styles.td}>%{participant}</td>
          <td %{Styles.td_num}>#{Fmt.bytes row.bytes_to_write}</td>
        </tr>
      |})
  in
  let body =
    match rows with
    | [] -> empty_row "No live connections."
    | _ :: _ ->
      {%html|
        <div %{Styles.table_wrap}>
          <table %{Styles.table}>
            <thead>
              <tr>
                <th %{Styles.th}>Peer</th>
                <th %{Styles.th}>Participant</th>
                <th %{Styles.th_num}>Bytes queued</th>
              </tr>
            </thead>
            <tbody>*{rows}</tbody>
          </table>
        </div>
      |}
  in
  Panel.view ~title:"Connections — worst first" [ body ]
;;

let participants_pane (display : Display.t) =
  let rows =
    List.map display.participants ~f:(fun row ->
      {%html|
        <tr>
          <td %{Styles.td}>%{row.participant#Jsip_types.Participant}</td>
          <td %{Styles.td_num}>#{Fmt.rate row.submits_per_sec}</td>
          <td %{Styles.td_num}>%{row.resting_orders#Int}</td>
        </tr>
      |})
  in
  let body =
    match rows with
    | [] -> empty_row "No orders submitted yet."
    | _ :: _ ->
      {%html|
        <div %{Styles.table_wrap}>
          <table %{Styles.table}>
            <thead>
              <tr>
                <th %{Styles.th}>Participant</th>
                <th %{Styles.th_num}>Orders</th>
                <th %{Styles.th_num}>Resting</th>
              </tr>
            </thead>
            <tbody>*{rows}</tbody>
          </table>
        </div>
      |}
  in
  Panel.view ~title:"Participant activity — busiest first" [ body ]
;;

let symbols_pane (display : Display.t) =
  let rows =
    List.map display.symbols ~f:(fun row ->
      {%html|
        <tr>
          <td %{Styles.td}>%{row.symbol#Jsip_types.Symbol}</td>
          <td %{Styles.td_mono}>#{row.bid}</td>
          <td %{Styles.td_mono}>#{row.ask}</td>
          <td %{Styles.td_num}>%{row.bid_depth#Int}</td>
          <td %{Styles.td_num}>%{row.ask_depth#Int}</td>
        </tr>
      |})
  in
  let body =
    match rows with
    | [] -> empty_row "No books yet."
    | _ :: _ ->
      {%html|
        <div %{Styles.table_wrap}>
          <table %{Styles.table}>
            <thead>
              <tr>
                <th %{Styles.th}>Symbol</th>
                <th %{Styles.th}>Bid</th>
                <th %{Styles.th}>Ask</th>
                <th %{Styles.th_num}>Bid depth</th>
                <th %{Styles.th_num}>Ask depth</th>
              </tr>
            </thead>
            <tbody>*{rows}</tbody>
          </table>
        </div>
      |}
  in
  Panel.view ~title:"Book depth" [ body ]
;;

let engine_pane (display : Display.t) =
  let last_gap_ms = List.last display.max_gap_ms_series in
  let last_queue = List.last display.request_queue_series in
  let stats =
    {%html|
      <div %{Styles.stat_row}>
        <Stat.view
          ~label:%{"max gap (last poll)"}
          ~value:%{Option.value_map last_gap_ms ~default:"—" ~f:Fmt.ms} />
        <Stat.view
          ~label:%{"request queue"}
          ~value:%{Option.value_map last_queue ~default:"—"
                     ~f:Int.to_string} />
        <Stat.view
          ~warn:%{display.evictions > 0}
          ~label:%{"evictions"}
          ~value:%{Int.to_string display.evictions} />
      </div>
    |}
  in
  let gap_spark =
    Spark.view
      (List.map display.max_gap_ms_series ~f:(fun gap ->
         Some gap, Fmt.ms gap))
  in
  let events_spark =
    Spark.view
      (List.map display.events_per_sec_series ~f:(function
        | None -> None, "counter reset (exchange restart)"
        | Some rate -> Some rate, Fmt.rate (Some rate)))
  in
  Panel.view
    ~title:"Engine"
    [ stats
    ; gap_spark
    ; {%html|<div %{Styles.spark_label}>engine max gap per sample</div>|}
    ; events_spark
    ; {%html|<div %{Styles.spark_label}>events dispatched per second</div>|}
    ]
;;

let page (display : Display.t) =
  {%html|
    <div %{Styles.page}>
      %{header display}
      <main %{Styles.grid}>
        %{connections_pane display}
        %{participants_pane display}
        %{symbols_pane display}
        %{engine_pane display}
      </main>
    </div>
  |}
;;
