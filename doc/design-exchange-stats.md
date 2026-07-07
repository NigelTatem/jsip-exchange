# Design: exchange-stats instrumentation slice

Status: **approved plan, not yet implemented.** This is the design doc for the
redo of the dashboard's instrumentation layer. The browser dashboard itself is
a later, separately planned phase; this slice ends with a polled stats RPC and
a client `stats` command.

As with all docs in this repo: the `.ml`/`.mli` files are authoritative. Line
references below were verified against `main` at `e2efe6e`.

## Context

The v1 dashboard + stats instrumentation was built without planning and shipped
a metric that measured the wrong buffer: `pipe_occupancy` reported
`Pipe.length` of the dispatcher's per-subscriber pipe, but
`Rpc.Pipe_rpc.implement` eagerly drains that pipe (up to ~1000 elements per
batch) into the connection's transport `Writer` — so under `slow-consumers` the
exchange grew to ~2 GB RSS while the metric read ~0.

Everything from v1 is archived on branch `dashboard-v1-archive` (`e2a4d5f`);
`main` is at the clean base `e2efe6e`. Decisions already made: full clean slate
(restore nothing), and the snapshot should cover **all four metric families**
from the exercise spec (not just pick one).

This is a teaching project: design decisions marked **[STUDENT]** are left as
`TODO(human)` contributions (2–10 lines each, one at a time — never more than
one `TODO(human)` in the tree at once); Claude scaffolds plumbing, mli docs,
dune files, and tests around them.

## Where the bytes actually sit (the shape v1 got wrong)

```
Matching_engine ───▶ Dispatcher.dispatch
                      │  per-subscriber Pipe        ◀── layer 1: Pipe.length
                      │  (unbounded today;              (what v1 measured — reads ~0
                      ▼   bounded in Phase 5)            because Pipe_rpc drains it)
              Rpc.Pipe_rpc.implement  ── drains ≤1000/batch ───▶
                      transport Writer buffer       ◀── layer 2: Rpc.Connection.bytes_to_write
                      ▼                                  (where the 2 GB actually lived)
                    socket ───▶ client pipe
```

The snapshot must expose **both layers per subscriber/connection**; the bound
in Phase 5 applies at layer 1, and `bytes_to_write` is what proves the layer-2
residual stays bounded (~1 batch per flush cycle).

## The four metric families

Everything below is grounded in APIs that already exist; no matching-engine
interface changes are required except where noted.

### A. Buffer occupancy (per subscriber pipe, both layers)

Per-subscriber queue length for per-symbol market data, the audit log, and
per-session feeds — plus per-connection `Rpc.Connection.bytes_to_write` for
the transport layer. This is the metric family that catches slow consumers,
and the one v1 got wrong. Sources:

- Dispatcher pipes: `lib/gateway/src/dispatcher.ml:55-66` (needs labels — see
  Phase 3).
- Session pipes: `session.ml` writer; sessions already carry identity via
  `Session.participant`.
- Transport: `Rpc.Connection.bytes_to_write : t -> int` (verified in the
  `5.2.0+ox` switch, `async_rpc_kernel/connection_intf.ml:211-223`). First
  implementation step: compile a one-line use of it; if absent, drop the
  per-connection stat and note it, don't fake it.

### B. Per-participant activity: order rate + active resting orders

- **Submit counter** per participant, incremented in the matching loop
  (`exchange_server.ml:26-31`) where every `Order.Request.t` passes through
  and carries `request.participant`. **[STUDENT]** representation decision:
  cumulative count + snapshot timestamp (poller computes orders/sec from
  deltas — simpler, stateless) vs. a server-side rolling window (self-
  contained but needs pruning). Precedent worth reading first:
  how `Fundamental_oracle` handles time.
- **Active resting order count**: fold `Order_book.orders_on_side`
  (`order_book.mli:46`) over both sides of every symbol's book, group by
  `Order.participant` (`order.mli:44`). O(resting orders) per snapshot —
  fine for a polled RPC; no incremental counters needed.
  `Matching_engine` has no symbols accessor, but `Exchange_server.start
  ~symbols` already has the list in scope to capture.

Together these expose the read-only abuser signature: high backlog (family A)
with zero submits (family B).

### C. Book depth per symbol: live BBO + total resting size per side

Entirely derivable from existing queries: `Matching_engine.book` →
`Order_book.best_bid_offer` (`order_book.mli:56`) for the BBO, and
`Order_book.snapshot` → `Book.t` (`lib/types/src/book.mli`: `bids/asks :
Level.t list`) with a fold over `Level.size` for per-side totals. Include all
of the engine's symbols in the snapshot; the dashboard picks which to render.

### D. Matching-engine busyness

Two cheap, complementary signals, both sampled in/around
`start_matching_loop` (`exchange_server.ml:26-31`):

- **Iteration gap** (the spec's suggested approximation): elapsed `Time_ns`
  between successive iterations of the request-drain loop. Near zero when the
  engine keeps up; grows when each iteration does more work.
- **Request-queue length**: `Pipe.length` of the request reader — the direct
  backlog measure behind the gap. The queue is already bounded by
  `request_queue_size_budget = 1024` (`exchange_server.ml:19,43`), so this
  reads 0–1024.

**[STUDENT]** representation decision: last gap vs. max-gap-since-last-
snapshot vs. EWMA — what does a poller sampling every second actually need to
see a stall that lasted 50 ms?

## Verified facts (re-checked against `main`)

- `lib/gateway/src/dispatcher.ml:55-61` — `push_market_data` uses
  `Pipe.write_without_pushback_if_open`, no size budget. Same for audit
  (`:63-66`) and sessions (`session.ml:18`). Subscriber cleanup on
  `Pipe.closed` already exists (`dispatcher.ml:37-42`, `:49-51`) — "evict =
  close writer" is a one-liner.
- Dispatcher bags hold **bare** `Pipe.Writer.t` (`dispatcher.ml:6-8`) — no
  identity. A market-data subscriber's *same writer* is registered in
  **multiple per-symbol bags** (`dispatcher.ml:27-35`), so a naive per-bag
  fold would double-count backlog.
- `lib/gateway/src/exchange_server.ml:102-109` — `market_data_rpc` handler
  does `ignore state`; subscribers never log in (the v1 identity flaw).
  `initial_connection_state` (`:127`) receives both `_addr` **and** `conn`;
  `close_finished` cleanup pattern already at `:129-133`.
- `Connection_state.t` (`:33-37`) holds only `mutable session` — needs to
  carry `addr`/`conn` for attribution and `bytes_to_write`.
- `app/client` is a single binary, `app/client/bin/main.ml` (no `src/`).
  Commands are parsed by `lib/gateway/src/exchange_command.ml` (`Verb` enum
  with derived `of_string`, `:4-19`) — a `stats` command touches **both**.
- `slow-consumers` scenario fully implemented
  (`app/scenarios/src/slow_consumers.ml`: 4 noise traders + 30
  `Read_behavior.Never` slow consumers); runner starts the exchange
  in-process.
- `app/monitor` fully implemented (`src/`, `bin/`, 2 test files) — CLAUDE.md's
  "not done" bullet is stale. `app/server/bin/main.ml` takes only `-port`;
  CLAUDE.md's `-seed-market-maker` example is stale too.
- E2E test infra: `lib/test_harness/src/e2e_helpers.mli` — `with_server`,
  `connect_as`, `connection` (raw `Rpc.Connection.t` accessor), `rpc_submit`.
  Wire-contract pattern: `lib/gateway/test/test_rpc_shapes.ml` (bin-shape
  digests, one block per RPC — copy a block for the new RPC).

## Phases

### Phase 1 — Run and observe (no code)

- T1: `dune exec app/scenario_runner/bin/main.exe -- -scenario slow-consumers -port 12345 -seed 0`
- T2: `dune exec app/monitor/bin/main.exe -- -host localhost -port 12345`
- T3: `watch -n1 'ps -o rss=,cmd= -C main.exe'`
- Extra experiment: `kill -STOP <monitor pid>` — a true out-of-process slow
  socket, distinct from the in-process bots.
- **[STUDENT]** short hypothesis (scratch note): where do the bytes sit for
  (a) the in-process slow bots, (b) the stopped monitor? With numbers from T3.

*Done when:* RSS growth reproduced; hypothesis written.

### Phase 2 — Doc warm-up + trace the data flow (no production code)

- **[STUDENT]** fix CLAUDE.md: replace the `-seed-market-maker` example with a
  real `scenario_runner` command; correct the stale "app/monitor not done"
  bullet.
- Trace together, citing lines: `Dispatcher.dispatch` (`dispatcher.ml:97-135`)
  → per-subscriber pipe → `Pipe_rpc.implement` batch drain → transport
  `Writer` → socket → client pipe. Compare against the Phase-1 hypothesis.
- **[STUDENT — central design decision]** the snapshot record type (~10–15
  lines) in `exchange_stats.ml`, covering all four families: per-subscriber
  rows (label, pipe length), per-connection rows (peer, `bytes_to_write`),
  per-participant rows (submits, resting count), per-symbol rows (BBO, depth
  per side), engine row (gap representation, queue length), plus counters
  (events dispatched, drops, evictions).
- **[STUDENT]** identity decision: market-data subscribers never log in, so a
  submit/cancel-keyed roster can't show a read-only abuser. Key stats rows by
  connection peer address, session participant, or both?

*Done when:* snapshot type sketched and identity decision made.

**Phase 2 outcome (decided 2026-07-07):** rows are keyed by connection peer
address with `participant : Participant.t option` filled in after login
(`None` + backlog + zero submits = the read-only-abuser signature). Scope
stays the four families — no process memory or RPC latencies in this slice.
Family C covers all engine symbols. Family B is a cumulative submit counter
(the poller derives rates from deltas). Family D is
max-gap-since-last-snapshot (a 1 s poller still sees a 50 ms stall; last-gap
would miss it, EWMA would dilute it). The approved sketch is implemented as
`lib/gateway/src/exchange_stats.mli`.

### Phase 3 — `Exchange_stats` (pure) + sampling hooks

- NEW `lib/gateway/src/exchange_stats.ml`/`.mli` — the snapshot type
  (`[@@deriving sexp_of, bin_io]`, full mli docs, `Time_ns` timestamps).
- **Family A hooks** — `dispatcher.ml`/`.mli` [Claude scaffolds]:
  - Bag elements become a `subscriber` record `{ writer; label }` so backlog
    is attributable. To avoid double-counting the multi-symbol writer, keep
    one top-level `market_data_subscribers : subscriber Bag.t` registry
    alongside the per-symbol bags (added on subscribe, removed in the
    existing `Pipe.closed` handler) and fold over *that* for stats.
  - `subscribe_market_data`/`subscribe_audit` gain a `~label:string` argument
    (callers: `exchange_server.ml:107,112`, plus dispatcher tests).
  - Expose a read-only per-subscriber backlog fold (market data + audit +
    sessions; add a `Session.backlog` accessor in `session.ml`/`.mli`).
  - `exchange_server.ml`: extend `Connection_state.t` with `addr`/`conn`;
    track live connections in a `Bag` from `initial_connection_state`
    (removed on `close_finished` — extend the handler at `:129-133`).
- **Family B hooks** [Claude scaffolds the table; STUDENT already chose the
  representation in Phase 2]: a `Participant.Table.t` submit counter bumped
  in `start_matching_loop`; the resting-count fold over
  `Order_book.orders_on_side` for the captured `~symbols`.
- **Family C** [Claude scaffolds]: per-symbol fold —
  `Matching_engine.book` → `best_bid_offer` + `snapshot` level-size totals.
- **Family D hooks** [Claude scaffolds timing plumbing; the representation is
  the Phase-2 STUDENT decision]: iteration timestamps in
  `start_matching_loop` + `Pipe.length` of the request reader.
- **[STUDENT]** the snapshot-assembly fold itself (~8–10 lines): combine the
  four families into an `Exchange_stats.t`.
- Tests: NEW `lib/gateway/test/test_exchange_stats.ml` (mirror `test/dune`
  deps) — (a) subscribe with a label, push N unread events, snapshot shows N
  attributed; read some, snapshot drops (pattern: the audit-subscriber-count
  test at `test_end_to_end.ml:300-331`); (b) submit orders as two
  participants, snapshot shows per-participant submit counts and resting
  counts; (c) book depth matches a hand-built book.

*Done when:* `dune runtest` green with nonzero, attributed values for all four
families in expect output.

### Phase 4 — Expose it: `exchange_stats_rpc` + human surface

- `rpc_protocol.ml`/`.mli` —
  `exchange_stats_rpc : (unit, Exchange_stats.t) Rpc.Rpc.t` (plain polled RPC;
  streaming is dashboard-phase). Add a digest block to `test_rpc_shapes.ml`
  (copy an existing block; read the promote diff).
- `exchange_server.ml` — implement (~4 lines). **[STUDENT, 1 line]** bare
  response vs `Or_error`: snapshotting can't fail; `book_query_rpc` returns
  bare `Book.t option` (`rpc_protocol.mli:34`) as precedent.
- **[STUDENT]** ~10 lines: `Stats` verb in `exchange_command.ml` (`Verb` enum
  + parse arm, no args) and the dispatch-and-print-sexp case in
  `app/client/bin/main.ml`'s command loop — the human surface for Phase 6
  verification.
- E2E test in `test_end_to_end.ml`: subscriber that never reads + zero
  submits shows attributed backlog in stats — the read-only abuser is
  visible. (Use `connection` from `E2e_helpers` to dispatch the pipe RPC
  without reading, as the existing market-data tests do.)

*Done when:* e2e test green; live polling during `slow-consumers` shows
attributed backlog, per-participant rates, book depth, and engine busyness.

### Phase 5 — Bound the buffers (the real fix)

- `dispatcher.ml` (market-data + audit), `session.ml:18`, budget constant in
  `exchange_server.ml` next to `request_queue_size_budget` (`:19`).
- **[STUDENT — policy]** the ~5-line guard replacing the bare write in
  `push_market_data`: drop-newest vs drop-oldest vs disconnect (close writer
  — the existing `Pipe.closed` cleanup makes eviction automatic); gentler
  policy for audit subscribers?
- **[STUDENT — the constant]** named budget value, justified in a comment
  against Phase-1 observed event rates.
- [Claude scaffolds] drop/evict counters wired into `Exchange_stats`;
  `dispatcher.mli` docs now state the bounding contract.
- Honest limitation to document: up to ~1000 in-flight elements can still sit
  in the transport writer per flush cycle — the `bytes_to_write` stat is what
  proves the residual is bounded.
- Tests: dispatcher expect test (push budget+k unread → capped/closed/counted
  per policy) + e2e (slow subscriber capped/evicted, fast subscriber
  unaffected).

*Done when:* tests green and Phase 6 memory check passes.

### Phase 6 — Final doc fix + end-to-end verification

- **[STUDENT]** update CLAUDE.md's "backpressure smell" note
  (`dispatcher.ml:56,61` / `session.ml:18` bullet — now stale; describe the
  bounded design).
- Verification:
  1. `dune build && dune runtest` clean (read diffs before `--auto-promote`).
  2. `slow-consumers` for ~2 min: RSS plateaus instead of climbing toward GB.
  3. Poll `stats` from `app/client` live: backlog/drop/evict rows attributed
     to slow consumers showing **zero** submits; noise traders show nonzero
     order rates; AAPL depth and BBO move; engine gap stays near zero while
     backlog grows (proving the bytes sat in buffers, not the engine).
  4. `kill -STOP` the monitor: its connection's `bytes_to_write` rises, then
     the bounding policy engages.

*Done when:* all four checks pass on the student's machine.

## Implementation findings (2026-07-07)

Phases 3–5 are implemented (snapshot + hooks, `exchange_stats_rpc`, client
`STATS` command, evict-at-budget bounding with an `evictions` counter added
to the snapshot). Decisions taken during implementation: stats RPC response
is bare `Exchange_stats.t`, not `Or_error` (snapshotting can't fail;
`book_query_rpc` precedent); overflow policy is **evict** (close the pipe —
uniform for market-data, audit, and session feeds);
`subscriber_pipe_size_budget = 10_000`, justified against the measured
event rate below.

**The headline measurement — the doc's own diagram was incomplete.** Live
under `slow-consumers` (~1,925 events/sec dispatched, engine max-gap
~50 ms, request queue 0), the exchange-side buffers read **zero at both
layers** — every `pipe_length` ≈ 0 *and* every `bytes_to_write` ≈ 0 —
while the process RSS climbed ~10 MB/s. The bytes sit in a **third place**
the diagram stopped short of: the *bots' client-side* RPC pipes, which
live in the same OS process as the in-process exchange. A `Read_behavior.
Never` bot's async-rpc client keeps draining its socket into a pipe the
bot never reads. The exchange was innocent; shared-process RSS was the
misleading signal. (The stale claim in `slow_consumer.ml`'s comment was
corrected accordingly.)

Consequences: (a) server-side buffers only fill when a subscriber's
*socket* stops draining. We tested this with `kill -STOP` on
out-of-process subscribers — and found a **second, pre-existing
defense**: async-rpc's heartbeat timeout drops an unresponsive peer
after ~30 s, which at calm-market data rates fires *before* any buffer
fills (both frozen test clients vanished from the connection table with
`evictions` still 0 and every buffer at 0). The dispatcher's
evict-at-budget therefore guards the complementary case: a subscriber
alive enough to keep heartbeating whose pipe fills faster than
heartbeats can catch — burst regimes like `order_spam`, where 10k events
can arrive well inside the heartbeat window. The eviction mechanism
itself is pinned deterministically by the expect test in
`lib/gateway/test/test_exchange_stats.ml`. (b) Bounding the exchange
does **not** stop `slow-consumers` RSS growth (that memory is the bots'
own — ~1 GB after a few minutes); the exchange's health is proven by its
own stats reading zero, not by scenario RSS.

- The dashboard rebuild design note (feed→fold→render study of
  `app/monitor`), streaming stats, browser UI, dashboard-server reconnect.

## Critical files

- `lib/gateway/src/dispatcher.ml` + `.mli` (labels, top-level subscriber
  registry, backlog fold, bounding)
- `lib/gateway/src/exchange_server.ml` (connection tracking, submit counters,
  loop timing, snapshot, stats RPC, budget constant)
- `lib/gateway/src/exchange_stats.ml` + `.mli` (new)
- `lib/gateway/src/rpc_protocol.ml` + `.mli`, `lib/gateway/src/session.ml` +
  `.mli`
- `lib/gateway/src/exchange_command.ml` + `.mli`, `app/client/bin/main.ml`
  (stats command)
- `lib/gateway/test/{test_exchange_stats.ml (new), test_end_to_end.ml,
  test_rpc_shapes.ml}`
- `CLAUDE.md` (doc fixes, Phases 2 and 6)
