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
`https://github.com/digitalglobeby/Gingham` (`from: "1.1.0"`). It's free for tables of up to
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

**From source**: Xcode 26.4 or later (Xcode 26.0–26.3 can't import Gingham 1.1.0's binary
interface; Gingham 1.1.1 fixes that), then either open `Mac/GinghamBench.xcodeproj` and run the
`GinghamBench` scheme (it runs the Release configuration), or let the script build Release and
run everything:

```sh
Scripts/run-all.sh                            # 7 scenarios × 7 engines × 3 runs of 10 s, about 75 minutes
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
side, kept in step as Binance's documentation describes). **Numbers vary** with the market, the
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
table shows the same; `--gingham-extras` turns them on. Its rows are drawn by the GPU.
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
  (3–4 updates a second). `--swiftui-diff-moves` compares the two.
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

- **Updates shown a second**: callbacks that applied new data, the times a second the table got
  something new to show (at most the screen's refresh rate). The headline number.
- **Data age**: from a change's generation (Binance: its arrival from the network) to the callback
  that applied it, median and 99th percentile over the changes.
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
  **window server's GPU time** (it composites every app's layers; on a quiet Mac the bench's window
  is most of it), **energy** as the kernel accounts it to the process (`TASK_POWER_INFO_V2`, mostly
  the CPU's), **memory** (physical footprint) and the **thermal state**, sampled every 250 ms on
  another thread: work an engine moves off the main thread, or to the GPU, shows here.
- **Order check**: after each live run the feed stops, the last changes are applied, and the order
  the engine shows is checked against the store: every row once, in the scenario's order.
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

Final numbers come from runs on a quiet Mac and will be filled in here with the machine they ran
on and the raw JSON lines in [`results/`](results).

Machine: _to be measured_ · Gingham _version_ · display _Hz_ · Release build · `Scripts/run-all.sh`

| Scenario | Gingham | NSTableView | NSTableView, tuned | NSTableView, cell-based | NSCollectionView | SwiftUI Table | SwiftUI Table, tuned |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Live trades: 20,000 rows, ~44,800 changes a second | — | — | — | — | — | — | — |
| Order book: 200,000 rows, ~243,500 changes a second | — | — | — | — | — | — | — |
| Trade feed: 1,000,000 rows, ~300,000 changes a second | — | — | — | — | — | — | — |
| Binance tickers: ~3,100 pairs (live) | — | — | — | — | — | — | — |
| Binance order books: ~55,000 levels (live) | — | — | — | — | — | — | — |
| Sorting 1,000,000 rows by pair (~500 distinct) | — | — | — | — | — | — | — |
| Sorting 1,000,000 rows by account (nearly all distinct) | — | — | — | — | — | — | — |

Each cell: updates shown a second · data age (median) · main thread busy (sorts: time to the
sorted order · whether the screen kept drawing).

## Layout of the repository

- `Mac/`: the Mac app (`project.yml`, `GinghamBench.xcodeproj`, `GinghamBench/`):
  `App/` (launch arguments, window, window mode), `Engines/` (one file per engine), `Scenarios/`
  (the generator, the stores), `Binance/` (connection, decoding, book sync), `Data/` (columns,
  formatting, the apps' sorting), `Measure/` (meter, runner, report).
- `iOS/`: the iPhone and iPad app (below).
- `Shared/BenchKey.swift`: the license key for the bench's bundle id.
- `Scripts/run-all.sh`: build and run everything on the Mac; `Scripts/check-isolation.sh`: the
  check that the engines' hot code has no Swift 6 isolation checks; `Scripts/release.sh`: the
  maintainer's script that makes the notarized download.
- `results/`: published results (JSON lines and their tables).

## iPhone and iPad

`iOS/` is an app for iPhone and iPad (iOS 17 or later) that shows the same live table in five
engines (Gingham, UITableView, UICollectionView, SwiftUI Table and List) and measures how smoothly
each scrolls while values change. Its setup, measurement and the device script are described in
[`iOS/README-section.md`](iOS/README-section.md).

## Contributing

Pull requests that make any engine faster are welcome, the competitors above all; see
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

This repository is under the [MIT License](LICENSE). Gingham itself isn't open source: it's
free for tables of up to 10,000 rows, see its
[licensing](https://github.com/digitalglobeby/Gingham/blob/main/LICENSING.md).
