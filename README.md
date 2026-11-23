# Gingham Bench

An open benchmark of table views on the Mac (and on the iPhone and iPad): the same live
data in [Gingham](https://github.com/digitalglobeby/Gingham), `NSTableView` (as apps typically
write it, tuned the way an AppKit expert would, and in its cell-based mode), `NSCollectionView`
and SwiftUI's `Table` (as documented, and tuned), with how often each shows new data, how old
that data is, how busy the main thread is and the longest stall, measured the same way for each.

Gingham is a commercial table view whose source is closed. Its claims (that it keeps up with live
data where Apple's tables fall behind) are only worth something if anyone can check them, so
everything else is here: the data, the way each competitor is set up, the measurement, the scripts. If you
think an engine is used wrong, the code that uses it is a few hundred lines in
[`Mac/GinghamBench/Engines`](Mac/GinghamBench/Engines); open an issue or a pull request with a
faster way and it will be measured.

Gingham comes in as customers get it: the binary package
`https://github.com/digitalglobeby/Gingham` (`from: "1.1.1"`). It's free for tables of up to
10,000 rows; the bench registers a license key that unlocks every row only for its own bundle
id (`Shared/BenchKey.swift`), so the scenarios with hundreds of thousands of rows run as
measured.

## Download and run

**Prebuilt app** (signed with Developer ID and notarized): download `GinghamBench-<version>.zip`
from [Releases](../../releases), unzip it, open **Gingham Bench**. It needs macOS 14 or later on
Apple silicon (the SwiftUI Table engine needs macOS 14.4).

**Window mode** (open the app): pick a scenario and an engine and watch the updates a second,
the data's age and the main thread's load, live. This is for looking, screenshots and video; for numbers to compare
use the command line, which runs each engine in a fresh process with a warm-up and several runs.

**Command line**: the app measures and quits when started with `--scenario`:

```sh
"/Applications/Gingham Bench.app/Contents/MacOS/Gingham Bench" \
    --scenario all --engine all --seconds 10 --runs 3 --output ~/Desktop/bench.jsonl
```

It writes a JSON line per run and, next to it, a Markdown table (`bench.md`) with the median,
lowest and highest of the runs. Other arguments: `--scenario live-trades,order-book` (or `live`
for all but the sorts), `--engine gingham,nstable-tuned`, `--warmup 3`, `--rows N`,
`--load-timeout 30`, `--binance-domain binance.us`, `--window 1000x640`, `--gingham-extras`,
`--swiftui-diff-moves`, `--summarize file.jsonl`, `--check-formats`, `--calibrate-feed trades`,
and, in window mode, `--show order-book/collection` and `--cycle 7` (switches engines every
7 seconds, for recording). All of them are described in
[`Options.swift`](Mac/GinghamBench/App/Options.swift).

**From source**: Xcode 26 or later, then either open `Mac/GinghamBench.xcodeproj` and run the
`GinghamBench` scheme (it runs the Release configuration), or let the script build Release and
run everything:

```sh
Scripts/run-all.sh                            # 7 scenarios × 7 engines × 3 runs of 10 s + a screen pass, about 100 minutes
Scripts/run-all.sh --scenario live-trades     # any of the app's arguments
```

Results go to `results/<date>.jsonl` and `results/<date>.md`. (The time goes mostly to waiting:
Binance's request limit, SwiftUI's Table running out its timeouts, sorts on the main thread.) The project signs with the
maintainer's team; without its certificate the script builds "signed to run locally", and in
Xcode you pick your own team or "Sign to Run Locally" (the license key depends on the bundle id,
not on the signature). `Mac/project.yml` is the [XcodeGen](https://github.com/yonaskolb/XcodeGen)
spec the project is generated from; the generated project is committed, so XcodeGen isn't needed.

## Scenarios

| Scenario | Rows | Changes | Order | Data |
| --- | --- | --- | --- | --- |
| `live-trades` | 20,000 trades, 8 columns | ~44,800 a second | by amount, descending | generated, fixed seed |
| `order-book` | 200,000 orders, 8 columns | ~243,500 a second (incl. 50,000 inserts and 50,000 removals) | as they come | generated, fixed seed |
| `trade-feed` | 1,000,000 instruments, 23 columns | ~300,000 a second (incl. 1,000 inserts and 1,000 removals) | as they come | generated, fixed seed |
| `binance-tickers` | ~3,100 Binance pairs, 14 columns | what the market does (a few thousand a second) | by trades, descending | live, Binance's public streams |
| `binance-books` | ~50,000–58,000 order book levels of 6 pairs, 6 columns | what the market does | by pair, then price | live, Binance's public streams |
| `sort-text` | 1,000,000 trades, 8 columns | none | sorted on request by pair | generated, fixed seed |
| `sort-text-account` | the same | none | sorted on request by account | generated, fixed seed |

**Generated data** is made in the app, on a thread of its own, from a fixed seed: the same rows
and the same stream of changes on every run, every engine and every Mac. The generator ticks more
often than any screen refreshes (every 2–4 ms), so changes accumulate continuously; at every
screen refresh the main thread applies everything that came since the last one (below).

- `live-trades` is the comparison window of Gingham's README: 20,000 trades of 32 pairs; random
  trades get a new price and quantity (their amount, change and update count follow), 45,000 a
  second (the original app changed 750 sixty times a second; here 187.5 every 1/240 s, with the
  same generator, seed and steps). A trade changed twice within a tick counts once: about 44,800
  row changes a second.
- `order-book`: 200,000 resting orders of 500 instruments. Every 2 ms, 0.2% of the rows are
  picked, Zipf-distributed (exponent 1: the first rows the busiest, as in real markets); each
  is partially filled or repriced by 1–3 ticks. 50,000 new orders a second are added at the end
  and as many leave (filled ones first, then random cancels). A removed row's place is taken by
  the last row, so nothing shifts.
- `trade-feed`: 1,000,000 instruments with 23 fields (bid, ask, last, open, change, volume,
  trades, ten metrics, status, note…). Every 4 ms, 0.176% of the rows are picked (Zipf, exponent
  1); each changes three fields, half of the changes moving the price (last and change, and bid
  or ask when the price leaves the spread); 1% of the rows a second change status; 1,000
  instruments are listed and 1,000 delisted a second. About 300,000 row changes a second.
- The order book and trade feed follow two scenarios (`orders`, `firehose`) of the network feed
  server the first measurements used (whose trade feed ticked every 10 ms; the rate of picks here
  is set so the row changes a second are the same, `--calibrate-feed`). Generating in the app
  removes the network and the JSON decoding (which ran off the main thread there anyway) so that
  anyone can reproduce it.
- Zipf rank = row index: **the rows in view are the busiest rows**, by design. It is the hardest
  case for every engine (a table scrolled elsewhere would see fewer changes) and the one a trading
  screen shows.

**Binance** (`binance-tickers`, `binance-books`) is a live market, no account or key needed:
the 24-hour tickers of every pair (`!ticker_1d@arr`) and every pair's best bid and ask
(`<pair>@bookTicker`, over a few connections of 1,024 streams); or the order books of BTC, ETH,
SOL, BNB, XRP and DOGE against USDT (`<pair>@depth@100ms` on a REST snapshot of 5,000 levels a
side, kept in step as Binance's documentation describes). Sorted by pair and then price, highest
first, the rows in view are the top of the first pair's asks, 5,000 levels away from the market:
they hardly ever change, so this scenario shows about 0 screen updates for every engine, and what
it measures is the cost of keeping 58,000 levels sorted while the books change (main thread busy,
data age, updates applied). **Numbers vary** with the market, the
time of day and the network; compare engines within one session. Data doesn't arrive at every
screen refresh, so even an engine that keeps up shows fewer updates a second than the refresh
rate. Binance allows 6,000 request weight a minute per IP and bans IPs that go over, so the runs
check the weight used and wait for the next minute when their requests wouldn't fit. Where
`binance.com` is closed, use `--binance-domain binance.us`.

**`sort-text`** and **`sort-text-account`** are a static table of 1,000,000 trades, sorted by a
text column as a click on its header sorts it, three times from the unsorted order: by pair
(about 500 distinct pairs, the busiest far more frequent, as in the first measurement) or by
account (nearly every row a different name with a number, like "Zürich Partners 48213"). Text is
sorted in Finder's order (`localizedStandardCompare`: numbers by value, case and accents as
Finder does), and each run checks that the order shown is Finder's all the way down.

## Engines

Every engine reads the same store (the rows by column, kept on the main thread), shows the same
columns with the same widths, the same text for each value (numbers with grouping separators and
the same digits; `--check-formats` compares the other engines' text with Gingham's), striped rows,
20-point rows where the engine allows it, and is told about the same changes. Before the table,
everything is the same code: the generation (or the network and decoding), the batch, the store.
At every screen refresh (a display-link callback on the main thread) everything that came since
the last one is applied to the store in one batch, in the order it was made, and the engine is
told about each change, between `beginUpdates`/`endUpdates`: rows added at the end, a row removed
with the last row moved into its place, and the rows whose values changed with the columns that
changed (rows that changed a column the table is sorted by are told apart from the others). So an
engine that keeps up gets new data to show at every refresh; one that doesn't gets bigger batches
less often.

The app is in the Swift 6 language mode with main-actor default isolation. A closure made in a
main-actor function checks that it runs on the main thread every time it's called, which made the
typical NSTableView's sort comparator about 18 times slower; every hot closure and loop of the
app-side engines (comparators, the incremental sort's merge, the store's batch, the per-cell
paths) is in a `nonisolated` helper, and `Scripts/check-isolation.sh` (run by `run-all.sh`) fails if
the Release binary's hot functions call the check.

### Gingham

As an app would use it, through its public API: a data source that returns each cell's value,
`sortsRows` with `sortDescriptors` (the table sorts the rows itself, as a header click sets them),
and targeted reloads inside `beginUpdates`/`endUpdates`: `insertRows(at:)`,
`removeRowReplacingWithLast(at:)` and `reloadData(forRows:columnIndexes:)` with only the changed
columns. The data source also implements two optional calls of Gingham's data source protocol
that hand over a range of rows' numbers at once (`numbersFor`, `sortNumbersFor`); NSTableView and
SwiftUI have nothing like them. Gingham's change highlights and summary row are off, so every
table shows the same; `--gingham-extras` turns them on. By default Gingham pauses live sorting
while the pointer is over the table (so rows don't move under a user's pointer); the bench turns
that off (`pausesLiveSortUnderPointer = false`), because the other engines re-sort wherever the
pointer is and a pointer resting on the window would otherwise spare Gingham the re-sorting. (The
screen meter found it: with the pointer over the window, Gingham's sorted rows didn't move during
the feed.) Its rows are drawn by the GPU.
[`GinghamEngine.swift`](Mac/GinghamBench/Engines/GinghamEngine.swift)

### NSTableView

As apps typically write it: view-based, one `NSTextField` label per cell, reused through
`makeView(withIdentifier:owner:)`, its text set from the store's value whenever the table asks
for the cell; fixed 20-point rows. NSTableView doesn't sort, so the app does: when the scenario is
sorted, after every batch it sorts all rows again (Swift's `sort` with a comparator reading the
store's arrays; text compared with `localizedStandardCompare`) and reloads the rows in view (any
of them may show another record now), or the whole table when the number of rows changed.
Unsorted, the changes go through NSTableView's documented targeted updates inside
`beginUpdates`/`endUpdates`: `insertRows(at:withAnimation:)`, `removeRows(at:withAnimation:)` for
the last row, and `reloadData(forRowIndexes:columnIndexes:)` for the changed rows in view, with
only their changed columns. A header click sets `sortDescriptors`; the app sorts in
`tableView(_:sortDescriptorsDidChange:)`, on the main thread.
[`NSTableEngine.swift`](Mac/GinghamBench/Engines/NSTableEngine.swift)

### NSTableView, tuned

What an AppKit expert would write for live data, every choice aimed at doing less per frame:

- **Cells**: a plain `NSTextField` label per cell (no `NSTableCellView`, no Auto Layout: the
  table sets the frame), reused per column. A cell remembers its text and sets `stringValue` only
  when the text differs, so an unchanged cell is neither laid out again nor redrawn.
- **Fixed geometry**: `rowHeight` 20 with `rowSizeStyle = .custom` and no automatic row heights;
  no column autoresizing; a layer-backed scroll view.
- **No reloads through the table**: at the end of a batch, the cells in view whose text changed
  get it in place (`view(atColumn:row:makeIfNecessary: false)`): only the changed rows in view,
  only their changed columns. Rows out of view aren't touched; they're read when they scroll in.
  A change in the number of rows is one `noteNumberOfRowsChanged()` per batch instead of per-row
  inserts and removes.
- **Incremental sorting**: every row's sort key is computed once and kept (numbers as they are,
  text as its rank among the column's distinct texts, so rows compare by Doubles). After a batch
  only the rows whose key changed are taken out and merged back into the order:
  O(rows + changed × log changed), no full sort per frame.
- **Sorting a static table** (a header click on `sort-text`) runs in the background and the table
  keeps showing the old order until the new one is ready. The distinct texts are ranked once
  (500 for the pair column, so that part is quick; nearly a million for the account column), then
  the rows are sorted by rank on all cores. The texts are compared on one thread:
  `localizedStandardCompare` doesn't get faster across cores (measured: 4 threads 1.2 times faster
  than one, 8 threads slower than one).

Where its main thread goes, from a profile (`sample`, 4 seconds of `trade-feed`): Core Animation's
commit 47%, inside it 44% displaying layers, of which a quarter of the main thread is AppKit drawing
the changed labels into their layers (text layout and drawing alone 9%), and layout 11%; applying
the feed to the store about 4% and the engine's own bookkeeping under 2%. On `live-trades`: the
commit 36%, displaying layers 34%.
[`NSTableTunedEngine.swift`](Mac/GinghamBench/Engines/NSTableTunedEngine.swift),
[`TunedRows.swift`](Mac/GinghamBench/Engines/TunedRows.swift),
[`AppSort.swift`](Mac/GinghamBench/Data/AppSort.swift)

### NSTableView, cell-based

The first thing AppKit veterans suggest for big, busy tables: NSTableView's older cell-based mode
(discouraged by Apple since macOS 10.10, still working). No views per cell: the table draws every
visible cell itself with one `NSTextFieldCell` per column (`dataCell`), asking the data source for
each value as it draws (`tableView(_:objectValueFor:row:)`). Tuned like the view-based one: at the
end of a batch only the changed cells in view are marked for drawing
(`setNeedsDisplay(frameOfCell(atColumn:row:))`, the whole row for a row that shows another record),
fixed 20-point rows, one `noteNumberOfRowsChanged()` per batch, and the same incremental sort. (A
variant where one view draws a whole row isn't measured: the cell-based table already draws all
cells in one view.)
[`NSTableCellsEngine.swift`](Mac/GinghamBench/Engines/NSTableCellsEngine.swift)

### NSCollectionView

AppKit's counterpart of `UICollectionView`, set up the way an expert would for many rows: each
row an item with a label per column at the columns' widths (plain `NSTextField`s with frames, text
set only when it changes), items reused through `makeItem(withIdentifier:for:)`, and a custom
layout for fixed 20-point rows that computes an item's frame from its index (nothing cached or
measured per item, unlike `NSCollectionViewFlowLayout`, which prepares every item's attributes).
Changes update the items in view in place (`item(at:)`); a change in the number of rows is one
batch of item inserts or deletes at the end. Sorting is the tuned NSTableView's. It has no column
header, so a row of labels above it shows the columns.
[`CollectionEngine.swift`](Mac/GinghamBench/Engines/CollectionEngine.swift)

### SwiftUI Table

As SwiftUI's documentation shows it, in an `NSHostingView`: an `@Observable` model with the rows
as an array of `Identifiable` values (each row's values, its id the record's identity), the
columns made with `TableColumnForEach`, each cell a `Text` of the value with its format style,
sorting through the `sortOrder` binding (a header click changes it, and the app sorts the rows
with it: `Table` shows rows in the order given). A batch changes the rows in place: the array is
taken out of the model for the batch (one change for the view to see, no copy), changed values
written, rows appended or the last one moved into a removed row's place, then put back. Sorted,
the rows are kept in the store's order apart and sorted into the model at the end of each batch.
Its rows' height is SwiftUI's own (there's no API for it on the Mac).

Its table style is `.inset(alternatesRowBackgrounds: true)`, the closest to the others' striped
full-width look that SwiftUI offers on the Mac.

### SwiftUI Table, tuned

What an expert would do to give SwiftUI less to compare and redraw:

- Rows are `@Observable` objects with a stored property per column, and each cell is a small view
  that reads only its own property: a changed value updates that cell alone, with no array change
  and nothing to diff. A value is assigned only when it differs (an assignment notifies even when
  the value is equal).
- The columns are written out statically (`TableColumn`s in the table's builder, a Table for each
  column count the scenarios have) instead of `TableColumnForEach` over an array of values.
- Unsorted, the rows array changes only when rows come or go, in place; it's never replaced.
- Sorted, the order is kept by the same incremental sort as the tuned AppKit engines, and when it
  changes the table gets the reordered rows with a new `.id`, so SwiftUI builds the table afresh
  instead of working out every row's move. Measured on `live-trades`: diffing the moves left the
  main thread stuck for 2.4 s at a time (0 updates a second); building afresh takes about 0.3 s
  (3–4 updates a second). `--swiftui-diff-moves` compares the two. A new `.id` also resets the
  table's scrolling and selection, which a real app would have to keep itself (the bench neither
  scrolls nor selects).
[`SwiftUITunedEngine.swift`](Mac/GinghamBench/Engines/SwiftUITunedEngine.swift)

### Both SwiftUI engines

Whether the table has its rows is read from the `NSTableView` SwiftUI uses inside the hosting
view. An engine that shows no rows within `--load-timeout` seconds (30) is reported as exactly
that ("no rows shown within 30 s"); in `sort-text`, a sort that doesn't reach the screen within
60 seconds is reported as such, with the sorts done before it.
[`SwiftUIEngine.swift`](Mac/GinghamBench/Engines/SwiftUIEngine.swift)

## How it's measured

Each run of an engine is a **new process** of the app: no engine runs after another in the same
process (no warm caches or leftovers), and a table that hangs can't stop the others. Engines take
turns within each round of runs, so a slow drift of the machine (heat, background work) spreads
over all of them. A run makes the scenario's rows (not measured), shows the engine's table in the
window, waits until the table has its rows, starts the feed, waits the warm-up (3 seconds, 5 for
Binance) and measures for `--seconds` (10). Everything is recorded with timestamps and
summarized over that window afterwards; a watchdog thread writes the result if the main thread
never comes back.

Frames are counted by a `CADisplayLink` of the window's screen, asked for the screen's full rate:
its callbacks run on the main thread, once per screen refresh when the main thread is free to take
it. Each callback applies the changes that came since the last one (above). Per engine:

- **Screen updates a second (table)**: what the eye sees, measured from outside every engine. The
  app captures its own window with ScreenCaptureKit (only that window, at up to the display's
  rate, at half its size in points, on a background queue); it gets a frame whenever the window's
  content changed, and a frame counts when the table's body changed: its pixel rows are compared
  with the previous frame's (the rectangles ScreenCaptureKit reports as changed cover the whole
  window), leaving out the top bar with its live numbers, the column header and the scroller
  strips. Also the median share of the table's rows that changed in one. The headline number.
  Data that changes off the screen changes no pixels: on `live-trades`, sorted by amount, only
  about half of the frames' changes reach the 30-odd rows in view, so even an engine that applies
  every frame's changes shows about 50–60 screen updates a second there; on the feeds whose
  busiest rows are in view, nearly every update shows.
  It needs the **Screen Recording permission** of the process that captures: the app's when it's
  opened from the Finder, the terminal app's when it runs from the command line (System Settings ›
  Privacy & Security › Screen & System Audio Recording). Without it the column says why it's
  empty. Measured cost: within run-to-run noise for most engines, up to about 5% fewer updates for
  one already saturated (the tuned NSTableView on `order-book`: 48 against 50–51); so `run-all.sh`
  measures without it and runs one more round of every scenario and engine with it
  (`--separate-screen-pass`), whose screen numbers fill the column. Each sort run also checks the
  meter: two seconds after the sorts, with nothing changing, should give about 0 screen updates
  while the callbacks go on. `GINGHAM_BENCH_VISIBLE_TRUTH=1` adds the data's own answer on
  `live-trades`: the callbacks after which the 30 top rows by amount look different
  (`visibleDataChangesPerSecond`), and whether the engine shows exactly those rows in that order
  one frame later (printed after the run); `=26` counts the top 26 rows instead of 30. Checked
  that way (26 rows, about those in the meter's region for every engine): Gingham 72.5 screen
  updates a second against 69.5 data changes, the tuned NSTableView 58.8 against 59.5, the
  cell-based one 68.3 against 69.8.
- **System frames a second (trace)**: the system's own count, from an Instruments trace of one more
  run of each engine on `live-trades` and `order-book` (`--trace-pass`, also through `run-all.sh`;
  only the Hitches and Display instruments: the whole Animation Hitches template slowed the traced
  run to 60 frames a second). No trace table is per window on macOS (the display's "Displayed
  Surfaces" are the whole screen's framebuffers), but two are per process: the Core Animation
  commits that went into a display frame (`hitches-updates`, with the frame's swap ID) and the GPU's
  accesses to surfaces (`metal-io-surface-access`): Gingham draws its table into a surface the
  window server then reads to composite. The column counts the display frames that got new content
  from the bench's window either way, once each. During that run the top bar's live numbers stay
  still, so the commits are the table's. Instruments attaches to the run's process
  (`xctrace record --attach`): launched by `xctrace --launch`, a binary inside an app bundle goes
  through Launch Services, which may start another copy of the app with the same bundle id. Each
  trace (10 seconds at most) is read right after it's recorded and deleted, with the raw kernel
  trace Instruments leaves behind in the temporary folder (`instruments*.ktrace`, 1–2 GB each), one
  on the disk at a time, in `~/Library/Caches/gingham-bench-traces`; the pass stops with less than 40 GB free.
  What it showed (one run each, a busy Mac): Gingham's GPU frames the window server read equal its
  own presented frames (114.2 and 114.2 on `live-trades`, 119.2 and 119.2 on `order-book`); for the
  AppKit engines the display frames with new content equal the updates applied when every update
  changes something in view, and come close to the data's visible changes when not (the tuned
  NSTableView: 59.2 against 59.0). It is an upper bound of what changes on the screen: a frame
  with the same pixels counts too (Gingham presents a frame for every batch applied, the cell-based
  table redraws the changed cells: 114–116 such frames a second on `live-trades` where the screen
  meter and the data agree on about 70 visible changes). In the traced run the screen meter also
  read about 17% low for the view-based tuned engines, so the screen numbers come from runs
  without a trace.
- **Updates applied a second**: callbacks that applied new data, the times a second the table was
  given something new to show (at most the screen's refresh rate). Whether each update then
  reached the screen, only Gingham can tell (`GHTableView.framePresented`); its **frames
  presented** a second are shown next to it. No other engine has a way to report that. The window's
  big number is the screen updates when the meter runs, and these otherwise.
- **Data age**: from the time a change was due in the feed (Binance: its arrival from the network)
  to the start of the callback that applied it, median and 99th percentile over the changes. It
  ends there: that frame's applying, layout, commit and presentation aren't in it. Ticks keep the
  time they were due even when the generator waits for a slow engine (below), so an engine that
  falls behind shows it here.
- **Main thread busy**: the share of time the main run loop wasn't waiting (run loop observers of
  `afterWaiting`, running first, and `beforeWaiting`, running last): applying the changes, layout,
  drawing, Core Animation's commit, everything the app and the framework do on it. Less is more
  room for the app's own work.
- **Longest stall**: the longest time between two callbacks, the longest the screen waited for the
  main thread (8.3 ms at 120 Hz when nothing is missed).
- **Callbacks a second** ("responsiveness"): callbacks the main thread got to, new data or not.
- **Changes applied a second**: row changes applied to the store and told to the engine. The
  generator waits when more than a second of changes is waiting for the main thread, so an engine
  that can't keep up gets fewer changes; the table flags runs below 95% of the feed's rate.
- **Process CPU** (all threads, 100% is one core), the process's **GPU time** (the GPU driver's
  accumulated time of the process's GPU clients, what Activity Monitor's GPU column shows), the
  **window server's GPU time** above its rate in two seconds before the feed starts (the table
  shown, nothing changing; it composites every app's layers, so this is Mac-wide), and **the two
  together**: the work lands in different places, AppKit's drawing composited under the window
  server, Gingham's drawn in the process. Only increases between samples count (a GPU client that
  closes takes its time with it). Also the process's **CPU energy** as the kernel accounts it
  (`task_energy` of `TASK_POWER_INFO_V2`): the CPU's alone, not the GPU work the process does
  (Gingham draws its table on the GPU), not the window server's compositing (AppKit's drawing is
  composited there); so it isn't total energy, and the column says "CPU energy". Also **memory** (physical footprint) and the **thermal state**, sampled every 250 ms on
  another thread: work an engine moves off the main thread, or to the GPU, shows here.
- **Order check**: after each live run the feed stops, the last changes are applied, and the order
  the engine shows is checked against the store: every row once, in the scenario's order. For the
  view-based AppKit tables, whose cells can be read, the text of every cell in view is checked
  against the store too (a stale in-place update fails).
- **Crashes**: a run that crashes is reported as a failed run ("crashed", with the crash's kind
  and the crashed thread's top frames) and the process ends without macOS's dialog, so an
  unattended run goes on (`--crash-reports` leaves crashes to macOS instead). An engine whose rows
  lose step with the store's changes rebuilds them and the order check reports it, instead of an
  index out of range; `--self-test` (run by `run-all.sh`) replays order book changes into every
  engine without the network and checks both.
- **Interruptions**: a run during which the window was covered (Gingham stops drawing what isn't
  seen, which would favor it), the screen locked, the screen saver started or the display slept is
  reported as invalid.
- **`sort-text`**: from the request to the first display-link callback after the new order is in
  place (for engines that sort on the main thread, that's after their sort returns and the next
  commit), the callbacks that came meanwhile and the longest gap between them ("the screen keeps
  drawing" when it stays short). Three sorts per run, each from the unsorted order.

The Markdown table gives, per scenario and engine, the median, lowest and highest of the runs; the JSON
lines have every second of every run, the machine (model, chip, cores, memory, macOS version,
Gingham's version from `GHTableView.version`, the screen and its refresh rate, Low Power Mode,
thermal state, build configuration) and the date.

### Caveats

- **The refresh rate caps the frames**: 120 on a MacBook Pro's display, 60 on most external
  ones. The window opens on the display with the highest rate; numbers from 60 Hz and 120 Hz
  displays aren't comparable.
- **Release build**: debug builds of the app's own code are several times slower; the script
  and the Xcode scheme build Release.
- **Low Power Mode off, on power, other apps closed**, nothing building, indexing or syncing,
  and don't touch the Mac during a run: the window floats above other windows (a covered window
  isn't drawn), and a busy machine lowers every number. The app turns off App Nap while
  measuring, for every engine alike.
- **The window's size** decides how many cells are in view, the work every view-based engine does
  per frame: 1000 × 640 points of table by default, the same for all (`--window`).
- **The data is the bench's**: the shapes and rates come from real feeds (a trading terminal, an
  order book, a market data firehose), but your app's data and columns are yours. The code is
  small enough to change the scenarios.
- **SwiftUI's Table** gets the same rows but its own row height and style; on hundreds of
  thousands of rows its numbers are mostly about whether it shows them at all.
- **Binance numbers** change with the market and the network.
- **No scrolling is measured on the Mac**: the tables stay at the top, where the busiest rows are.
  (The iPhone and iPad bench measures scrolling while values change.)
- **The window server's CPU time isn't measured** (another user's process); its GPU time is.

## Results

Measured on 2026-11-23 with `Scripts/run-all.sh` (3 runs of 10 s each, medians), on a MacBook Pro
(MacBookPro18,2, Apple M1 Max, 10 cores, 32 GB), macOS 27.2.1, Gingham 1.1.1, the built-in display
at 120 Hz, Release build. The full tables (every column, lowest and highest of the runs) and the
raw JSON lines: [default window](results/2026-11-23-1146.md) ([JSON](results/2026-11-23-1146.jsonl)),
[2040 × 1080](results/2026-11-23-1358.md) ([JSON](results/2026-11-23-1358.jsonl)).

### Live data, the default window (1000 × 640 points of table)

Screen updates a second (the table's pixels, measured from outside) · main thread busy · data age
(median, from the change to the frame that applied it).

| Engine | Live trades: 20,000 rows, ~44,800 changes/s | Order book: 200,000 rows, ~243,500 changes/s | Trade feed: 1,000,000 rows, ~300,000 changes/s |
| --- | --- | --- | --- |
| Gingham | 73 · 48% · 6 ms | 111 · 55% · 5 ms | 110 · 37% · 7 ms |
| NSTableView | 42 · 96% · 12 ms | 19 · 99% · 27 ms | 10 · 99% · 49 ms |
| NSTableView, tuned | — · 65% · 8 ms | 52 · 98% · 10 ms | 42 · 98% · 13 ms |
| NSTableView, cell-based | 58 · 48% · 4 ms | 94 · 84% · 5 ms | 96 · 83% · 6 ms |
| NSCollectionView | 52 · 65% · 8 ms | 52 · 98% · 9 ms | 42 · 98% · 13 ms |
| SwiftUI Table | 0 · 100% · 4,608 ms | stuck (no frames for 15 s after the window) | stuck (no frames for 15 s after the window) |
| SwiftUI Table, tuned | 4 · 100% · 138 ms | stuck (no frames for 15 s after the window) | stuck (no frames for 15 s after the window) |

On `live-trades` only about 60% of the frames' changes reach the rows in view (the table is sorted
by amount), so ~70 screen updates a second is all any engine can show there; Gingham and the
cell-based NSTableView apply every frame's changes (118–119 updates applied a second), the others
fewer. The tuned NSTableView's screen-meter run was invalid (the window was covered); its traced
run read 50 screen updates a second.

### Live data, a large window (2040 × 1080 points of table)

At this size the trace isn't reliable (the Instruments recording held every engine near 60 frames a
second, Gingham's presented frames too) and neither is the screen meter for this purpose (in its
untraced runs it saw 91–92% of the frames Gingham presented, but at this size it gets close to what
the capture can take). So: Gingham's presented frames (exact, counted by Gingham, and matching the
system's trace at the default size) or, for the others, the updates applied a second (the most an
engine can have shown) · main thread busy · data age. The full table has the meter's and the trace's
columns too, marked where the recording slowed the run.

| Engine | Live trades | Order book | Trade feed |
| --- | --- | --- | --- |
| Gingham | 120 presented · 38% · 4 ms | 120 presented · 35% · 5 ms | 119 presented · 73% · 6 ms |
| NSTableView | 27 applied · 96% · 21 ms | 10 applied · 99% · 53 ms | 4 applied · 99% · 117 ms |
| NSTableView, tuned | 47 applied · 93% · 13 ms | 31 applied · 97% · 17 ms | 14 applied · 96% · 37 ms |
| NSTableView, cell-based | 114 applied · 75% · 5 ms | 76 applied · 97% · 7 ms | 40 applied · 96% · 15 ms |
| NSCollectionView | 48 applied · 93% · 12 ms | 32 applied · 97% · 17 ms | 15 applied · 98% · 36 ms |
| SwiftUI Table | stuck (no frames for 15 s after the window) | stuck (no frames for 15 s after the window) | stuck (no frames for 15 s after the window) |
| SwiftUI Table, tuned | 2 applied · 100% · 242 ms | stuck (no frames for 15 s after the window) | 0 applied · 100% · 5,938 ms |

### Sorting 1,000,000 rows by a text column

Time to the sorted order on the screen · longest stall meanwhile (the screen kept drawing when it
stays near 8 ms). By pair has about 500 distinct texts, by account nearly a million.

| Engine | By pair | By account |
| --- | --- | --- |
| Gingham | 0.15 s · 16 ms | 0.18 s · 14 ms |
| NSTableView | 5.18 s · 5,183 ms | 7.99 s · 7,993 ms |
| NSTableView, tuned | 0.16 s · 77 ms | 7.85 s · 79 ms |
| NSTableView, cell-based | 0.09 s · 8 ms | 7.83 s · 17 ms |
| NSCollectionView | 0.11 s · 8 ms | 7.81 s · 35 ms |
| SwiftUI Table | no sorted order within 60 s | no sorted order within 60 s |
| SwiftUI Table, tuned | 0.92 s · 797 ms | 13.29 s · 890 ms |

### Binance (live market: numbers vary)

Tickers (about 3,100 pairs, sorted by trades): screen updates a second · main thread busy · data
age (from arrival). The order books' rows in view hardly change (see Scenarios), so for them:
updates applied (Gingham: presented) · main thread busy · data age.

| Engine | Tickers | Order books (~55,000 levels) |
| --- | --- | --- |
| Gingham | 39 · 19% · 4 ms | 11 presented · 9% · 5 ms |
| NSTableView | 26 · 94% · 12 ms | 10 applied · 87% · 32 ms |
| NSTableView, tuned | 36 · 36% · 4 ms | 18 applied · 31% · 4 ms |
| NSTableView, cell-based | 43 · 43% · 4 ms | 22 applied · 22% · 6 ms |
| NSCollectionView | 44 · 37% · 4 ms | 18 applied · 19% · 4 ms |
| SwiftUI Table | 25 · 94% · 15 ms | 1 applied · 100% · 828 ms |
| SwiftUI Table, tuned | 21 · 64% · 8 ms | 5 applied · 91% · 70 ms |

### iPhone

iPhone 15 Pro Max (iPhone16,2), iOS 27.2.1, Gingham 1.1.1, 120 Hz, Release build, 2026-11-23; the
JSON summaries are in [`results/ios`](results/ios).

The app's own tests (`flicks`: scrolling as fast as a flick, down and up, while values change;
median of 3 runs): frames a second · hitch time (ms a second) · main thread busy.

| Engine | 100,000 rows, 1,000 changes/s | 1,000,000 rows, 10,000 changes/s |
| --- | --- | --- |
| Gingham | 120 · 0 ms/s · 20% | 120 · 0 ms/s · 31% |
| UITableView (typical) | 62.4 · 480.2 ms/s · 82% | 6.3 · 947.8 ms/s · 98% |
| UITableView (tuned) | 120 · 0 ms/s · 36% | 120 · 0 ms/s · 40% |
| UICollectionView (typical) | 120 · 0 ms/s · 43% | 120 · 0 ms/s · 40% |
| UICollectionView (tuned) | 120 · 0 ms/s · 40% | 120 · 0 ms/s · 41% |
| SwiftUI List | 119.7 · 2.1 ms/s · 40% | 120 · 0 ms/s · 48% |

Instruments' Animation Hitches on the device (render-side hitches, all three scroll tests of one
run, hitch time a second): Gingham 1.6–8.3 ms/s, UITableView (typical) 503–507, UITableView
(tuned) 1.0–3.6, UICollectionView (typical) 0–2.1, UICollectionView (tuned) 0–9.9, SwiftUI List
3.1–5.2.

XCUITest flicks (UIKit's own scroll metric, five flicks each): no hitches and 116–119 frames a
second for every engine (Gingham 117.7, UITableView tuned 119.0, UICollectionView typical 116.0 and
tuned 118.7, SwiftUI List 117.3) except the typical UITableView: 294 hitches, a hitch time ratio of
72.5 ms a second, 111 frames a second.

## Layout of the repository

- `Mac/`: the Mac app (`project.yml`, `GinghamBench.xcodeproj`, `GinghamBench/`):
  `App/` (launch arguments, window, window mode), `Engines/` (one file per engine), `Scenarios/`
  (the generator, the stores), `Binance/` (connection, decoding, book sync), `Data/` (columns,
  formatting, the apps' sorting), `Measure/` (meter, runner, report).
- `iOS/`: the iPhone and iPad app (below).
- `results/`: the published results: the Mac's JSON lines and tables, the iPhone's JSON summaries
  (`results/ios`).
- `Shared/BenchKey.swift`: the license key for the bench's bundle id.
- `Scripts/run-all.sh`: build and run everything on the Mac; `Scripts/check-isolation.sh`: the
  check that the engines' hot code has no Swift 6 isolation checks; `Scripts/release.sh`: the
  maintainer's script that makes the notarized download; `Scripts/publish.sh`: the maintainer's
  script that creates the public repository and its release.
- `results/`: published results (JSON lines and their tables).

## iPhone and iPad

`iOS/` is an app for iPhone and iPad (iOS 17 or later) that shows the same
live table in seven engines and measures how smoothly each one scrolls:

- **Gingham**, from the public binary package
  (`https://github.com/digitalglobeby/Gingham`, the same build any app links)
- **UITableView (typical)** and **UITableView (tuned)**
- **UICollectionView (typical)** and **UICollectionView (tuned)**
- **SwiftUI Table** (iPad only, see below)
- **SwiftUI List**

Every engine shows the same rows: a campaign's name and six numbers (clicks,
views, spend, revenue, profit, ROI), formatted the same way (US English,
whatever the device's region), in 15-point text, rows 24 points high, the same
column widths, no column header, filling the same area; each run records the
rows each engine had on screen. While the tests run, a feed changes rows'
spend (and the profit and ROI that follow from it), 1,000 times a second by
default. 20% of the changes go to the rows on or near the screen (about 200 a
second over some 20 rows), the rest to any row; with random rows alone, a
dozen rows out of 100,000 would almost never change while you watch.
`-screenShare` sets the share.

### Three measurements

1. **Render-server hitches, real flicks** (`iOS/UITests`): XCUITest launches
   the app with one engine (values changing as in the app's tests), flicks the
   table up and back down, five times over after a warm-up flick, and measures
   each flick with `XCTOSSignpostMetric.scrollingAndDecelerationMetric`: the
   hitch time ratio, frame rate and frame count of UIKit's own scrolling and
   deceleration, as the render server showed them. This counts everything
   that makes a frame late, wherever the work happens. A caveat: XCUITest
   switches on the accessibility runtime for the whole app, which users
   without VoiceOver don't have, and it likely costs more for engines with a
   view per cell (UIKit's labels, SwiftUI's views) than for Gingham, which
   has none. The app hides the engines from accessibility under the UI tests
   (XCUITest would otherwise snapshot UITableView's 100,000 rows, longer than
   it waits), which lessens but doesn't remove that cost. So the Animation
   Hitches recordings below, made without XCUITest, are the primary
   render-side measurement; the UI tests add real touches and UIKit's own
   deceleration. XCUITest also waits for the app to go idle before each
   gesture; UITableView (typical) never does while values change, so its test
   takes about a quarter of an hour.
2. **Render-server hitches, the app's tests** (Instruments' Animation
   Hitches; the primary render-side figure): one recording per engine while the app runs its tests below;
   `iOS/Scripts/hitches-summary.py` attributes every hitch to the test it
   happened in (the app marks each test with an os_signpost interval) and
   gives each test's hitch count, hitch time and hitch time ratio.
3. **The app's own meter: main-thread frame callbacks** (secondary). The app
   asks the display for its full rate (120 frames a second on ProMotion) and
   counts its display link's callbacks on the main thread, one per refresh
   while the main thread keeps up. It reports frames a second, the worst
   second, the longest frame, a hitch time modeled on Apple's hitch time ratio
   (but from main-thread callbacks), how busy the main thread was, the
   process's CPU time (all its threads; 100% is one core) and how long each
   frame's update call took (applying the changes and telling the engine).
   That last figure is the call alone and isn't comparable across engines:
   UIKit's typical engines do their work in the call, while Gingham and
   SwiftUI only note the change there and do the work later, at layout and
   drawing (counted in the frames, the main thread's load and the CPU time).
   It can't see work done after the main
   thread hands a frame over (the render server, the GPU, an engine's own
   drawing), which is why the first two come first.

Hitches and hitch time ratio follow Apple's definitions: a hitch is a frame
shown later than expected; the ratio is the total time frames were late, in
milliseconds per second (under 5 ms/s is good, over 10 is bad).

### The app's tests

For each engine and run, the app makes the rows anew from the same seed (the
feed restarts its sequence too), makes the engine anew, shows it for two
seconds, scrolls it down and up for two seconds without measuring (a
warm-up: cells, caches and text made once), then measures three tests of
eight seconds each, half a second apart:

- **steady scroll**: down at 3,000 points a second (125 rows) for four
  seconds, back up for four;
- **fast scroll**: the same at 8,000 points a second (333 rows);
- **flicks**: a flick every second, four down and four up, each starting at
  8,000 points a second and slowing down like UIScrollView's deceleration.

Positions come from the time of each frame, so a dropped frame leaves the
content further along, as under a finger. Touches are ignored during the
tests. Engines take turns (each once, then each again; three runs by
default), so a device warming up doesn't favor the first one. Each result also
records what the test really did: the changes made (and how many on screen),
how far it scrolled, the rows' measured height, the rows on screen, the
columns shown, the refresh interval the display gave, and the thermal state at
the start and the worst during the test. Summaries give each figure's median
over the runs and its worst.

### How each engine is set up

Each is written the way its framework's guidance has it for a fast live
list; the code explains every choice (`iOS/GinghamBench/*Engine*.swift`).

- **Gingham**: columns with formats, a data source that returns each cell's
  value, and a targeted reload of the changed cells
  (`reloadData(forRows:columnIndexes:)`). `-ginghamExtras YES` adds what
  Gingham usually shows and the others don't: a header, a pinned name column
  and a live summary row (every column's average over all rows).
- **UIKit, both engines**: fixed row heights (`rowHeight` 24 with estimates
  off; a compositional layout of absolute 24-point items), a reused cell whose
  content is seven labels laid out with frames (no Auto Layout), cached number
  formatters, cell prefetching on, focus off (`allowsFocus = false`), a plain
  data source (the rows never move, appear or disappear; a diffable data
  source would diff every identifier on each change).
- **typical**: changed rows near the screen are reconfigured
  (`reconfigureRows(at:)`, `reconfigureItems(at:)`), Apple's recommended way
  to update a cell since iOS 15. For UITableView each call's cost grows with
  the table's row count: measured in the iPhone simulator, 3.7 ms at 10,000
  rows, 30 ms at 100,000 and 300 ms at 1,000,000, whichever rows are passed.
  UICollectionView's took 0.9 ms at 100,000 rows and 3.3 ms at 1,000,000.
- **tuned**: the app keeps a map of rows to the cells showing them (filled
  when a cell is configured) and sets changed values on those cells itself,
  without asking UIKit to do anything; cells kept off screen or prefetched are
  updated too, so none shows a stale value.
- **SwiftUI Table and List**: rows given directly (stable `Identifiable`
  ids, no `AnyView`, no indices); each row is an `@Observable` object with a
  property per column, and each number is a small view that reads only its
  own property, so a change updates that cell alone with nothing to diff.
  Fixed column widths; List's rows are 24 points (no vertical insets); no
  header (`tableColumnHeaders(.hidden)`).
- SwiftUI Table's rows can't be made lower: we measured 44 points in the
  iPhone simulator (iOS 18) and 52 in the iPad simulator (iOS 27.2) with this
  text, whatever `defaultMinListRowHeight`, row insets or the cells' frames
  say; each run records the height it measured. So that Table brings the same
  rows a second onto the screen as the others, the tests move it faster in
  points by the same factor (e.g. 6,500 points a second for the steady
  scroll on iPad); its results show both.
- On iPhone, SwiftUI Table shows only its first column, as a list, in any
  orientation or size class (by design). It would do a fraction of the work,
  so iPhone runs leave it out unless it is named (`-engine swiftUITable`).
- On iPhone the app runs in landscape, the only orientation where all seven
  columns fit; the tables stay inside the safe area.

The app itself is a UIKit app (no SwiftUI around the UIKit engines); the
SwiftUI engines are each in their own `UIHostingController`. It's built in
Release, in the Swift 6 language mode.

### Running it on a device

Measure on a device, in a Release build. The simulator draws with the Mac,
and Instruments can't record hitches there.

With a device connected (Xcode 26 or later):

```sh
iOS/Scripts/run-device.sh              # the app's tests: 100,000 rows at 1,000 changes/s, then 1,000,000 at 10,000
iOS/Scripts/run-device.sh --ui-tests   # real flicks, render-server metrics (XCTOSSignpostMetric)
iOS/Scripts/run-device.sh --hitches    # Animation Hitches traces, one per engine, attributed to each test
iOS/Scripts/run-device.sh --all        # all three
iOS/Scripts/run-device.sh -- -engine gingham,tableViewTuned -rows 1000000 -rate 10000
```

The script picks the first connected iPhone or iPad (or `--device <UDID>`),
builds the app in Release with the repository's commit recorded, installs it
with `devicectl` and launches it with launch arguments that run the tests by
themselves; it copies everything into `iOS/results/`: the app's JSON reports
and logs, the UI tests' `.xcresult` and its metrics
(`xcresulttool get test-results metrics`) as JSON, and the `.trace` files with
their summaries. To sign with your own team, set `DEVELOPMENT_TEAM=<team id>`.

From Xcode: open `iOS/GinghamBench.xcodeproj`, run the "Gingham Bench" scheme
(Release, without the debugger), and tap **Test** (the engine shown) or
**Run All**; Product > Test runs the UI tests.

Launch arguments (each `-name value`):

| Argument | Default | |
| --- | --- | --- |
| `-autoTest YES` | | run the tests at launch |
| `-engine` | all (but SwiftUI Table on iPhone) | `gingham`, `tableView`, `tableViewTuned`, `collectionView`, `collectionViewTuned`, `swiftUITable`, `swiftUIList`, comma separated, or `all` |
| `-rows` | 100000 | rows |
| `-rate` | 1000 | changes a second |
| `-screenShare` | 0.2 | share of the changes made to rows on or near the screen |
| `-profiles` | steady,fast,flicks | the tests |
| `-speed` / `-fastSpeed` | 3000 / 8000 | points a second for 24-point rows |
| `-duration` | 8 | seconds each test lasts |
| `-warmUp` | 2 | seconds of unmeasured scrolling first |
| `-settle` | 2 | seconds each engine shows before that |
| `-runs` | 3 | runs of each engine |
| `-ginghamExtras YES` | | Gingham's header, pinned column and summary row |
| `-exitWhenDone YES` | | quit when done |

The app prints one JSON object a line: `BENCH_DEVICE`, `BENCH_BUILD`,
`BENCH_START`, `RESULT` (each test), `BENCH_SUMMARY` (each engine and test:
medians and worst), `BENCH_FILE`, `BENCH_DONE`; and writes a JSON report to its
Documents (`latest.json` and a dated copy, also in the Files app) with the
device model, iOS version, the display's maximum rate, Low Power Mode, whether
a hardware keyboard was attached, the build (configuration, the bench's
commit, Xcode and SDK versions, Gingham's version), the date and every test.

### Before measuring

- **Low Power Mode off**: it caps the display at 60 frames a second. The
  report records it.
- **No keyboard attached**: the UIKit engines have focus off, but the report
  records whether a hardware keyboard was attached; compare runs without one.
- **Cool and quiet**: the device at room temperature, not charging hard,
  other apps closed. Each test records the thermal state; compare tests that
  stayed `nominal` or `fair`.
- **120 Hz on iPhone** needs `CADisableMinimumFrameDurationOnPhone` in the
  Info.plist (the bench has it) or iPhones cap an app at 60. The report records
  the display's maximum, and each test the refresh interval it got.
- On iPad, the app full screen (not in a smaller window beside others).
- Don't touch the screen while the tests run.

## Contributing

Pull requests that make any engine faster are welcome, the competitors above all; see
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

This repository is under the [MIT License](LICENSE). Gingham itself isn't open source: it's
free for tables of up to 10,000 rows, see its
[licensing](https://github.com/digitalglobeby/Gingham/blob/main/LICENSING.md).
