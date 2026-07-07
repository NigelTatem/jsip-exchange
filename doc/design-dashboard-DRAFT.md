# DRAFT Design: dashboard rebuild (feed → fold → render)

> **Status: approved and implemented through D5 (2026-07-07).** The
> student approved this plan and made the open calls, all recorded here:
> **D2 = Option A** (raw `Exchange_stats.t` samples on the wire; the pure
> browser controller computes rates and renders counter resets as gaps);
> **D3 = 120 samples** (~2 min window); **D4 = retry + staleness flag**
> (`exchange_connected` on the wire, badges in the UI, reconnect verified
> live); first pane = connections, per this doc's recommendation; and the
> engine-gap poller interference is resolved by convention — **the
> dashboard server is the poller of record**; humans read stalls off the
> dashboard and use the client `STATS` command for spot checks of
> everything else. Implementation lives in `app/dashboard/`
> ({protocol,controller,server,client}); `Exchange_stats` moved to
> `lib/types` so the jsoo client can link the wire type. D6 (scenario
> walk-through with eyes on the browser) remains.
>
> Line references below were verified against the 2026-07-07 working tree
> and the archive branch `dashboard-v1-archive` (`e2a4d5f`); archived
> files are cited as `dashboard-v1-archive:path:line`.

## Scope and dependency

This is the deferred dashboard phase from `doc/design-exchange-stats.md`.
The stats slice ends with a polled
`exchange_stats_rpc : (unit, Exchange_stats.t) Rpc.Rpc.t`
returning the snapshot type that already exists at
`lib/gateway/src/exchange_stats.mli`. **Dependency: stats-slice Phase 4
(the RPC + client `stats` verb) must land before Phase D2 onward can
start.** This design can be reviewed now.

The prescribed shape (from the stats-slice decisions we inherit): the
dashboard server polls the exchange once per second, keeps a rolling window,
computes rates from the snapshot's **cumulative** counters — `submits`
(`exchange_stats.mli:62-64`) and `events_dispatched`
(`exchange_stats.mli:106-107`) never reset; "rate = delta between snapshots
over delta `taken_at`" is designed into the type
(`exchange_stats.mli:16-18`) — and serves a Bonsai web UI.

---

## 1. Reference architecture: a feed → fold → render study of `app/monitor`

The monitor is the well-built precedent in-tree. Its whole design is one
idea applied three times: **each layer is pure except the outermost one**,
and the boundaries between layers are plain data types.

### (a) Feed — subscribing (`app/monitor/bin/main.ml`)

The binary owns all I/O setup and nothing else:

- `connect_to_exchange` (`bin/main.ml:14-28`) opens the raw
  `Rpc.Connection.t`.
- `subscribe_audit_log` (`bin/main.ml:30-39`) dispatches
  `Rpc_protocol.audit_log_rpc` and extracts the pipe.
- `main` (`bin/main.ml:41-49`) hands the pipe to `Term_app.app` and starts
  the Bonsai loop. The caller "hands us a pipe and is otherwise oblivious to
  how events make it into the controller" (`src/term_app.ml:302-305`).

Inside `Term_app`, the pipe crosses into Bonsai exactly once:
`drain_events_on_activate` (`src/term_app.ml:281-289`) runs
`Pipe.iter_without_pushback`, injecting each event as an
`Action.Feed_event` (`src/term_app.ml:10-15`) into a single
`Bonsai.state_machine` whose model *is* the controller
(`src/term_app.ml:292-300`). Keyboard input enters through the same funnel
as `Action.Handle_key`. So the entire app has one state, advanced by one
`apply_action` that just delegates to two pure functions.

### (b) Fold — the pure controller (`app/monitor/src/controller.{ml,mli}`)

`Controller.t` is "the monitor's pure state machine"
(`src/controller.mli:1-12`): no Async, no terminal, and "the only
bonsai_term type it touches is `Event.Key.t`, which is a plain variant".
The state is five immutable fields (`src/controller.ml:40-46`); the
transitions are `feed_event` (`src/controller.ml:57` — one-line delegation
to the also-pure `Event_log`, `src/event_log.mli:1-8`) and `handle_key`
(`src/controller.ml:112-117`).

The output boundary is just as deliberate: `display : t -> Display.t`
(`src/controller.ml:148-190`) projects state into a record "decoupled from
any bonsai_term type so the controller is fully testable as plain data"
(`src/controller.mli:30-53`) — strings, chip records, `(Color.t * string)`
pairs. The controller decides *what* is visible (filter compilation,
`src/controller.ml:119-146`); it knows nothing about *how* it looks.

### (c) Render — `Term_app` (`app/monitor/src/term_app.ml`)

Rendering is a pure function too: `render_display : Display.t -> View.t`
(`src/term_app.ml:190-198`), built from small per-row renderers
(`render_chip` :40-49, `render_bbo_panel` :123-136, ...). The impure Bonsai
wiring — scroller sizing, key routing (`Routing.of_event`,
`src/term_app.ml:229-255`), exit handling — lives only in `app`
(`src/term_app.ml:292-368`). Concerns the controller shouldn't know about
stay here, explicitly: the auto-scroll footer hint is appended in the render
layer because "the controller doesn't know about scrolling"
(`src/term_app.ml:175-181`).

### How the tests exploit the separation (`app/monitor/test/`)

Neither test file starts a server, opens a terminal, or touches Async — the
test `dune` (`app/monitor/test/dune`) depends on `bonsai_term` only for the
`Event.Key.t` variant and Notty for offline rasterization.

- **Fold tested as data**: `test_controller.ml:7-14` — `feed_all` is a plain
  `List.fold` of `Harness.sample_events` (one of each event variant,
  `lib/test_harness/src/harness.mli:93-96`) through `Controller.feed_event`;
  `press` applies `handle_key`. Whole user interactions are folds of
  keystroke lists (e.g. type-then-commit, `test_controller.ml:226-243`).
- **Render tested without a terminal**: `render_to_string`
  (`test_controller.ml:21-29`) rasterizes "the same `View.t` the bonsai_term
  loop renders" through Notty's dumb capability into plain ASCII, via the
  exported pure renderer `Term_app.For_testing.render_display`
  (`src/term_app.mli:25-36`). So each expect block is a full-screen snapshot
  (`test_controller.ml:39-53`) produced with zero Bonsai machinery.
- **Properties as booleans**: quit behavior is `[%test_result: bool]` on
  `should_exit` after a pure transition (`test_controller.ml:80-103`).
- **The inner model tested separately**: `test_event_log.ml:16-21` folds
  the same sample events through `Event_log` alone.

The rebuild must preserve exactly this property: everything interesting
reachable from `dune runtest` as pure data.

## 2. What v1 did (archived at `dashboard-v1-archive`, `e2a4d5f`)

Files: `app/dashboard/{protocol,controller,client,server}` (from
`git ls-tree -r dashboard-v1-archive --name-only`). Honest summary: the
*shape* was largely right — it consciously mirrored the monitor — but it was
fed by the wrong instrumentation and had operational holes.

### What was reusable in shape

- **A pure, unit-tested controller.** `dashboard-v1-archive:app/dashboard/controller/controller.mli:1-11`:
  "no Bonsai, no Async, no js_of_ocaml... This mirrors
  `app/monitor/src/controller.ml`: `feed_*` advances the state, `display`
  projects it." It held a 60-sample rolling window (`controller.ml:5,29-46`),
  projected a render-ready `Display.t` (`controller.ml:79-93`), and ranked
  participants worst-first with a stability tie-break (`controller.ml:59-77`).
  Its tests (`controller/test/test_controller.ml:43-56,100-131`) verify
  window trimming, series extraction, `last_seen_at`, and ranking — pure,
  fast, no server.
- **The server as a thin RPC-to-websocket bridge.** A browser can't speak
  Async-RPC-over-TCP, so `server/main.ml:8-14` bridges: subscribe to the
  exchange, buffer ~120 samples (`:18-38`), serve `index.html` + the jsoo
  bundle + the RPC over websocket on one HTTP port via
  `Rpc_websocket.Rpc.serve` (`:112-143`). This topology is forced by the
  browser and carries over unchanged.
- **Poll-with-high-water-mark, and its rationale.**
  `protocol/jsip_dashboard_protocol.mli:8-14`: the browser polls with the
  timestamp of its newest sample; "a backgrounded browser tab simply stops
  asking, whereas a server-pushed stream would pile up unread diffs"; the
  high-water mark prevents misses and double-counts across reconnects. The
  protocol lib was kept Async-free (`async_rpc_kernel` only) so jsoo can
  link it (`:16-17`).
- **The client wiring.** `client/app.ml` is only 53 lines: a
  `Bonsai.state_machine` around the controller (`:18-26`) plus
  `Rpc_effect.Rpc.poll` every second (`:12,41-50`); `panes.ml` had a
  self-contained bar sparkline (`panes.ml:20-50`) and a page of four panes
  (`panes.ml:162-174`).

### What was wrong

- **The wire type measured the wrong metric.** The centerpiece
  `Pipe_occupancy` (`dashboard-v1-archive:lib/types/src/stats_snapshot.mli:68-78`)
  reported dispatcher-side `Pipe.length` maxes — layer 1 of the buffering
  picture — while `Rpc.Pipe_rpc` eagerly drains that pipe into the transport
  writer, so under `slow-consumers` the metric read ~0 while RSS hit ~2 GB
  (`doc/design-exchange-stats.md`, Context). The dashboard faithfully
  charted a number that could not show the failure it existed to show.
- **Identity flaws.** Two of them: (i) the pipe stats were anonymous
  *maxes* per family (`market_data_max`, ...) — no attribution to a
  subscriber, so even if the number moved you couldn't name the culprit;
  (ii) per-participant stats were keyed by logged-in `Participant.t`
  (`stats_snapshot.mli:88`), but market-data subscribers never log in —
  the read-only abuser was structurally invisible. The new `Exchange_stats`
  fixes both: labeled subscriber rows (`exchange_stats.mli:27-31`) and
  connection rows keyed by peer with `participant : Participant.t option`
  (`exchange_stats.mli:44-49`).
- **No reconnect anywhere.** The server connects once and raises on failure
  (`server/main.ml:86-100`); the stats pipe is drained in a fire-and-forget
  `don't_wait_for` with no `Pipe.closed` handling (`:102-110`). If the
  exchange restarts, the buffer silently freezes while the HTTP server keeps
  answering polls with stale data. The browser compounds it: poll errors are
  swallowed (`client/app.ml:38-39`, `| Error _ -> Effect.return ()`) and
  there is no staleness indicator.
- **Windowed metrics baked into the wire.** `orders_last_sec` /
  `cancels_last_sec` (`stats_snapshot.mli:58-66`) and per-second latency
  percentiles (`:28-51`) made the *exchange* pick the averaging window and
  run a per-second publish loop. The redo's snapshot deliberately inverts
  this: cumulative counters, "so the server never has to pick an averaging
  window" (`exchange_stats.mli:16-18`).

## 3. Proposed rebuild plan

Same three-layer shape as the monitor and as v1's good bones, but fed by
`exchange_stats_rpc`. The pieces:

```
exchange ──(exchange_stats_rpc, polled 1/s)──▶ dashboard server
   │  Exchange_stats.t (cumulative counters)     │ rolling buffer of samples
   │                                             │ (+ maybe derived rates — [STUDENT])
   └── no dashboard-specific code in the exchange│
                                                 ▼
             browser ──(poll over websocket)──▶ pure Controller ──▶ Bonsai panes
```

Per project convention this stays a teaching plan: **[STUDENT]** items are
`TODO(human)` contributions, one at a time; Claude scaffolds plumbing, mli
docs, dune files, and tests around them.

### Phase D0 — Prerequisite gate (no code)

- Stats-slice Phase 4 must be merged: `exchange_stats_rpc` in
  `rpc_protocol.{ml,mli}` and the client `stats` verb. Verify with a live
  `stats` poll during `slow-consumers` (that slice's own done-criterion).
- Re-read this doc against the merged code; the snapshot type may have
  drifted from `exchange_stats.mli` as reviewed here.

### Phase D1 — Study + skeleton (mostly no production code)

- Walk `app/monitor` with the section-1 citations above (student drives).
- Lay out `app/dashboard/{protocol,controller,client,server}` dune skeletons
  mirroring v1's split — the split itself was sound. Protocol and controller
  libs must be Async-free so jsoo links them (precedent:
  `dashboard-v1-archive:app/dashboard/protocol/jsip_dashboard_protocol.mli:16-17`;
  note `Exchange_stats` itself is already `Core`-only + `Jsip_types`
  (`exchange_stats.mli:20-21`), so the browser can share the exact wire
  type).
- Toolchain sanity check: the switch has `bonsai_web`,
  `async_rpc_websocket` (verified via `opam list`); v1's client dune
  (`dashboard-v1-archive:app/dashboard/client/dune`) is the reference for
  jsoo flags and ppx set.

*Done when:* empty libs build; student can narrate feed→fold→render from
memory.

### Phase D2 — Wire protocol between browser and dashboard server

- Keep v1's poll-with-high-water-mark query shape
  (`Query.since : Time_ns.t option`,
  `dashboard-v1-archive:app/dashboard/protocol/jsip_dashboard_protocol.mli:23-35`)
  — its rationale (backgrounded tabs, no double-count) is unchanged.
- **[STUDENT — central decision] what travels on the wire, i.e. where rate
  computation lives:**
  - **Option A — forward raw `Exchange_stats.t` samples; the browser
    controller computes rates from deltas.** Pros: the wire type is the
    already-reviewed snapshot (no second type to design); the delta math
    lands in the pure controller where `dune runtest` covers it; the server
    stays a dumb buffer like v1's (`server/main.ml:20-38`). Cons: every
    client re-derives; the controller must handle counter resets (exchange
    restart ⇒ `submits` drops ⇒ negative delta) and non-uniform `taken_at`
    gaps.
  - **Option B — the dashboard server computes rates and serves a derived
    per-second sample type.** Pros: one place handles resets/gaps; the
    browser gets render-ready numbers; smaller payloads (server can strip
    rows). Cons: a second wire type to design and keep in sync; the rate
    logic moves into an Async server where it's harder to expect-test; the
    raw counters are hidden from the UI.
  - Either way, the reset rule needs deciding with it: on a negative delta,
    drop the sample? clear the window? mark a discontinuity the UI shows?
- Tests: bin-shape digest block for the new RPC, following
  `lib/gateway/test/test_rpc_shapes.ml`.

*Done when:* protocol lib compiles under jsoo and the wire decision is
written down here.

### Phase D3 — Pure controller + tests (the fold)

- `Controller.t`: rolling window of samples, `feed_samples`, `last_seen_at`,
  `display : t -> Display.t` — same signature discipline as
  `app/monitor/src/controller.mli:55-78` and v1's controller. Immutable list
  window is fine at this size (v1's note,
  `dashboard-v1-archive:app/dashboard/controller/controller.ml:29-31`).
- **[STUDENT] window length.** v1 hardcoded 60 samples ≈ 60 s
  (`controller.ml:5`). Options: 60 s (one bar per pixel-ish, matches v1's
  sparklines), 5 min (catches slow leaks like the RSS climb, but 300 bars
  need bucketing to render), or two windows (recent + long, more state).
  What incident from Phase 1 of the stats slice would you want to still see
  on screen a minute after it ended?
- **[STUDENT — if Option A in D2] the rate function** (~10 lines): given two
  samples, produce submits/sec per participant and events-dispatched/sec,
  handling reset and gap. This is the one genuinely subtle pure function in
  the dashboard; it belongs where tests can hammer it.
- `Display.t` should carry, as plain data, whatever the chosen panes need
  (section D5) — e.g. connection rows sorted by `bytes_to_write` descending
  (the new snapshot's slow-reader signal), rate series, BBO/depth rows,
  engine-gap series, and a staleness field (age of newest sample).
- Tests in `app/dashboard/controller/test/`: window trimming, high-water
  tracking, ranking, reset handling — v1's own tests
  (`dashboard-v1-archive:app/dashboard/controller/test/test_controller.ml:43-97`)
  are a good structural template even though the sample type changes.

*Done when:* `dune runtest` exercises every `Display.t` field with no
server.

### Phase D4 — Dashboard server (the feed)

- Poll loop: `Clock.every'` (1 s) dispatching `exchange_stats_rpc`, append
  to a bounded ring buffer (v1's `Buffer`, `server/main.ml:20-38`, is the
  right ~30 lines — rewrite, don't restore). Serve the static page + bundle
  + websocket RPC as v1 did (`server/main.ml:112-143`).
- **[STUDENT — policy] reconnect.** v1 had none (section 2). Options:
  - *Retry with backoff*, buffer kept: dashboard survives exchange
    restarts; must decide what a poll answered from a stale buffer should
    say.
  - *Crash on disconnect* and rely on an outer restart: simplest and
    honest, but the browser sees a dead websocket, so the client needs its
    own reconnect story.
  - Orthogonal sub-decision: expose staleness on the wire (e.g. response
    carries `server_now` or `exchange_connected : bool`) vs. let the client
    infer it from sample age. v1's silent-stale failure mode is the thing
    to design away; don't let both sides assume the other handles it.
- Note one advantage of the polled RPC over v1's streamed pipe: a poll to a
  dead exchange *fails*, loudly, instead of a pipe quietly closing —
  reconnect becomes "retry the next poll", not "notice a closed pipe".

*Done when:* kill and restart the exchange under the dashboard; the
dashboard recovers (or dies) exactly per the chosen policy, visibly.

### Phase D5 — Bonsai web client (the render)

- Wiring is v1's 53-line `app.ml` shape: `Bonsai.state_machine` over the
  controller + `Rpc_effect.Rpc.poll`
  (`dashboard-v1-archive:app/dashboard/client/app.ml:18-50`) — but do **not**
  swallow poll errors as v1 did (`app.ml:38-39`); feed them to the
  controller so the display can show "disconnected/stale".
- Panes render `Display.t` only, never raw samples (v1's rule,
  `controller.mli` header). Sparkline approach from v1's `panes.ml:20-50`
  is reusable in spirit.
- **[STUDENT] which panes first.** Candidates, one per snapshot family:
  1. *Connections* — peer, participant-or-`None`, `bytes_to_write` series:
     the slow-consumer catcher and read-only-abuser table. Strongest claim
     to first: it's the pane v1 fundamentally could not build.
  2. *Participant activity* — submits/sec + resting orders: the
     spammer/book-filler pane.
  3. *Symbol depth* — BBO + per-side depth: most demo-friendly, least
     diagnostic.
  4. *Engine* — max-gap + request-queue series.
  Build one end-to-end before starting a second; resist the v1 failure mode
  of four panes over one wrong number.

*Done when:* first pane live against `slow-consumers`, showing an attributed
climbing `bytes_to_write` for a `kill -STOP`ped consumer.

### Phase D6 — End-to-end verification + docs

- Run the stats-slice Phase-6 scenario set with the dashboard attached;
  every pathological bot (`slow_consumers`, `order_spam`, `cancel_storm`,
  `book_fill`) should be identifiable from the screen alone.
- **[STUDENT]** update `CLAUDE.md`'s project-layout section to mention
  `app/dashboard`, and mark this doc's decisions as made.

## 4. Explicitly out of scope / open questions

Out of scope for this phase:

- **Streaming stats** (`Pipe_rpc` from the exchange) — explicitly deferred
  by the stats slice; the polled RPC is the contract.
- **New exchange-side instrumentation.** The dashboard consumes
  `Exchange_stats.t` as-is. In particular v1's memory pane (`live_words`,
  `stats_snapshot.mli:82-85`) and latency percentiles have **no equivalent
  in the new snapshot** — Phase 2 of the stats slice scoped them out.
  Rebuilding those panes would mean reopening that slice, not this one.
- Restoring any v1 code verbatim — the clean-slate decision stands; v1 is a
  reference to read, not a branch to merge.
- Auth, multiple exchanges, persistence of history across dashboard
  restarts, mobile layout.

Open questions to resolve during review:

1. **Poller interference on the engine gap.** `Engine.max_gap_since_last_snapshot`
   resets on read, so "concurrent pollers steal each other's peaks"
   (`exchange_stats.mli`). A dashboard polling 1/s makes the human `stats`
   command near-useless for gaps — and vice versa. Accept it, document it,
   or push a fix (e.g. never-resetting max + timestamp) back into the stats
   slice?
2. **Does the dashboard server dedupe pollers?** One ring buffer serves all
   browsers (v1's model) — but with resettable fields like the engine gap,
   the *server* being the single poller is actually what makes multiple
   browser tabs safe. Worth stating as an invariant.
3. **Sample identity across reconnects.** v1 keyed the high-water mark on
   the sample's own `at` (`jsip_dashboard_protocol.mli:25-27`). If the
   dashboard server restarts and re-polls, `taken_at` still comes from the
   exchange, so this probably still works — confirm once D2's wire type is
   chosen, especially under Option B where samples are derived.
4. **Browser-side tests.** The switch has `bonsai_web_test`. The monitor
   precedent (pure-render snapshots via `For_testing`) may be achievable for
   Vdom too — decide in D5 whether pane renderers get a `For_testing`
   escape hatch or the controller's `Display.t` tests are deemed enough.
5. **Where the sexp/human surface lives.** The stats slice gives a `stats`
   client command; should the dashboard server also expose its buffer as
   sexp over HTTP for curl-based debugging? Cheap, but one more surface to
   keep honest.

## Critical files

- Reference (read-only): `app/monitor/src/{controller,event_log,term_app}.{ml,mli}`,
  `app/monitor/bin/main.ml`, `app/monitor/test/{test_controller,test_event_log}.ml`
- Inherited contract: `lib/gateway/src/exchange_stats.mli`,
  `lib/gateway/src/rpc_protocol.{ml,mli}`,
  `doc/design-exchange-stats.md`
- Archive (read via `git show dashboard-v1-archive:...`, never restored):
  `app/dashboard/{protocol/jsip_dashboard_protocol.mli, controller/controller.{ml,mli},
  controller/test/test_controller.ml, server/main.ml, client/{app,panes,main}.ml}`
- New (this phase): `app/dashboard/{protocol,controller,controller/test,server,client}/`
