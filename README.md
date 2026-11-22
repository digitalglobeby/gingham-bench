# Gingham Bench

An open benchmark of table views on the Mac (and on the iPhone and iPad): the same live
data in [Gingham](https://github.com/digitalglobeby/Gingham), `NSTableView` (as apps typically
write it, and tuned the way an AppKit expert would), `NSCollectionView` and SwiftUI's `Table`,
with frames a second, how busy the main thread is and the longest stall measured the same
way for each.

Gingham is a commercial table view whose source is closed. Its claims ("120 frames a second
where NSTableView gets 30") are only worth something if anyone can check them, so everything
else is here: the data, the way each competitor is set up, the measurement, the scripts. If you
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

**Window mode** (open the app): pick a scenario and an engine and watch the frames a second and
the main thread's load, live. This is for looking, screenshots and video; for numbers to compare
use the command line, which runs each engine in a fresh process with a warm-up and several runs.

**Command line**: the app measures and quits when started with `--scenario`:

```sh
"/Applications/Gingham Bench.app/Contents/MacOS/Gingham Bench" \
    --scenario all --engine all --seconds 10 --runs 3 --output ~/Desktop/bench.jsonl
```

It writes a JSON line per run and, next to it, a Markdown table (`bench.md`) with the lowest and
highest of the runs. Other arguments: `--scenario live-trades,order-book` (or `live` for all but
the sort), `--engine gingham,nstable-tuned`, `--warmup 3`, `--rows N`, `--sort-column account`,
`--load-timeout 30`, `--binance-domain binance.us`, `--window 1000x640`, `--gingham-extras`,
`--summarize file.jsonl`, `--check-formats`, and, in window mode, `--show order-book/collection`
and `--cycle 7` (switches engines every 7 seconds, for recording). All of them are described in
[`Options.swift`](Mac/GinghamBench/App/Options.swift).

**From source**: Xcode 26.4 or later (Xcode 26.0–26.3 can't import Gingham 1.1.0's binary
interface; Gingham 1.1.1 fixes that), then either open `Mac/GinghamBench.xcodeproj` and run the
`GinghamBench` scheme (it runs the Release configuration), or let the script build Release and
run everything:

```sh
Scripts/run-all.sh                            # 6 scenarios × 5 engines × 3 runs of 10 s, about 25 minutes
Scripts/run-all.sh --scenario live-trades     # any of the app's arguments
```

Results go to `results/<date>.jsonl` and `results/<date>.md`. The project signs with the
maintainer's team; without its certificate the script builds "signed to run locally", and in
Xcode you pick your own team or "Sign to Run Locally" (the license key depends on the bundle id,
not on the signature). `Mac/project.yml` is the [XcodeGen](https://github.com/yonaskolb/XcodeGen)
spec the project is generated from; the generated project is committed, so XcodeGen isn't needed.

## Scenarios

| Scenario | Rows | Changes | Order | Data |
| --- | --- | --- | --- | --- |
| `live-trades` | 20,000 trades, 8 columns | ~44,000 a second | by amount, descending | generated, fixed seed |
| `order-book` | 200,000 orders, 8 columns | ~244,000 a second (incl. 50,000 inserts and 50,000 removals) | as they come | generated, fixed seed |
| `trade-feed` | 1,000,000 instruments, 23 columns | ~300,000 a second (incl. 1,000 inserts and 1,000 removals) | as they come | generated, fixed seed |
| `binance-tickers` | ~3,100 Binance pairs, 14 columns | what the market does (a few thousand a second) | by trades, descending | live, Binance's public streams |
| `binance-books` | ~50,000–58,000 order book levels of 6 pairs, 6 columns | what the market does | by pair, then price | live, Binance's public streams |
| `sort-text` | 1,000,000 trades, 8 columns | none | sorted on request by a text column | generated, fixed seed |

**Generated data** is made in the app, on a thread of its own, from a fixed seed: the same rows
and the same stream of changes on every run, every engine and every Mac.

- `live-trades` is the comparison window of Gingham's README: 20,000 trades of 32 pairs; 60
  times a second 750 random trades get a new price and quantity (their amount, change and update
  count follow). A trade picked twice in one tick counts once, so about 44,200 row changes a
  second reach the table.
- `order-book`: 200,000 resting orders of 500 instruments. Every 2 ms, 0.2% of the rows are
  picked, Zipf-distributed (exponent 1, the first rows the busiest, as in real markets); each
  is partially filled or repriced by 1–3 ticks. 50,000 new orders a second are added at the end
  and as many leave (filled ones first, then random cancels). A removed row's place is taken by
  the last row, so nothing shifts.
- `trade-feed`: 1,000,000 instruments with 23 fields (bid, ask, last, open, change, volume,
  trades, ten metrics, status, note…). Every 10 ms, 0.5% of the rows are picked (Zipf, exponent
  1); each changes three fields, half of the changes moving the price (last and change, and bid
  or ask when the price leaves the spread); 0.01% of the rows change status per tick; 1,000
  instruments are listed and 1,000 delisted a second.
- The order book and trade feed follow two scenarios (`orders`, `firehose`) of the network feed
  server the first measurements used. Generating in the app removes the network and the JSON
  decoding (which ran off the main thread there anyway) so that anyone can reproduce it.

**Binance** (`binance-tickers`, `binance-books`) is a live market, no account or key needed:
the 24-hour tickers of every pair (`!ticker_1d@arr`) and every pair's best bid and ask
(`<pair>@bookTicker`, over a few connections of 1,024 streams); or the order books of BTC, ETH,
SOL, BNB, XRP and DOGE against USDT (`<pair>@depth@100ms` on a REST snapshot of 5,000 levels a
side, kept in step as Binance's documentation describes). **Numbers vary** with the market, the
time of day and the network; compare engines within one session. Binance allows 6,000 request
weight a minute per IP and bans IPs that go over, so the order book runs check the weight used
and wait for the next minute when their snapshots wouldn't fit. Where `binance.com` is closed,
use `--binance-domain binance.us`.

**`sort-text`** is a static table of 1,000,000 trades, sorted by a text column as a click on its
header sorts it, three times from the unsorted order. `--sort-column pair` (the default, as in
the first measurement: about 500 distinct pairs, the busiest far more frequent) or `--sort-column
account` (nearly every row a different name with a number, like "Zürich Partners 48213"). Text is
sorted in Finder's order (`localizedStandardCompare`: numbers by value, case and accents as
Finder does), and each run checks that the order shown is Finder's all the way down.

## Engines

Every engine reads the same store (the rows by column, kept on the main thread), shows the same
columns with the same widths, the same text for each value (numbers with grouping separators and
the same digits; `--check-formats` compares the other engines' text with Gingham's), striped rows,
20-point rows where the engine allows it, and is told about the same changes. Before the table,
everything is the same code: the generation (or the network and decoding), the batch, the store.
Once per screen frame, the changes that came since the last frame are applied to the store in one
batch, in the order they were made, and the engine is told about each, between
`beginUpdates`/`endUpdates`: rows added at the end, a row removed with the last row moved into
its place, and the rows whose values changed with the columns that changed (rows that changed a
column the table is sorted by are told apart from the others).

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

Most of what's left of its main-thread time is Core Animation drawing the labels whose text
changed. A cell-based NSTableView (NSCell, discouraged since macOS 10.10) isn't measured.
[`NSTableTunedEngine.swift`](Mac/GinghamBench/Engines/NSTableTunedEngine.swift),
[`TunedRows.swift`](Mac/GinghamBench/Engines/TunedRows.swift),
[`AppSort.swift`](Mac/GinghamBench/Data/AppSort.swift)

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

- **Frames a second**: callbacks of a `CADisplayLink` of the window's screen, asked for the
  screen's full rate, which run on the main thread. It fires once per screen refresh when the
  main thread is free to take it; a main thread busy for longer misses refreshes. So this is how
  many screen refreshes the main thread got to, the most often it can update the table; it isn't
  a count of frames the window server composited. Gingham can tell when its frames are on the
  screen (`GHTableView.framePresented`), so for it the table also shows **frames presented**:
  it draws only when something visible changed, so with changes 60 times a second it presents
  about 60 frames a second at 120 Hz.
- **Worst second**: the fewest frames in any second of the window.
- **Main thread busy**: the share of time the main run loop wasn't waiting (a run loop observer
  of `beforeWaiting`/`afterWaiting`): applying the changes, layout, drawing, Core Animation's
  commit, everything the app and the framework do on it. Less is more room for the app's own work.
- **Longest frame gap**: the longest time between two display-link callbacks: the longest the
  screen waited for the main thread (8.3 ms at 120 Hz when nothing is missed).
- **Changes applied a second**: row changes applied to the store and told to the engine. The
  generator waits when more than a second of changes is waiting for the main thread, so an engine
  that can't keep up gets fewer changes, and this column shows it.
- **Process CPU** (all threads, 100% is one core) and **memory** (physical footprint), sampled
  every 250 ms on another thread: work an engine moves off the main thread shows here.
- **`sort-text`**: from the request to the first display-link callback after the new order is in
  place (for engines that sort on the main thread, that's after their sort returns and the next
  commit), the callbacks that came meanwhile and the longest gap between them ("the screen keeps
  drawing" when it stays short). Three sorts per run, each from the unsorted order.

The Markdown table gives, per scenario and engine, the lowest and highest of the runs; the JSON
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

## Results

Final numbers come from runs on a quiet Mac and will be filled in here with the machine they ran
on and the raw JSON lines in [`results/`](results).

Machine: _to be measured_ · Gingham _version_ · display _Hz_ · Release build · `Scripts/run-all.sh`

| Scenario | Gingham | NSTableView | NSTableView, tuned | NSCollectionView | SwiftUI Table |
| --- | --- | --- | --- | --- | --- |
| Live trades: 20,000 rows, ~44,000 changes a second | — | — | — | — | — |
| Order book: 200,000 rows, ~244,000 changes a second | — | — | — | — | — |
| Trade feed: 1,000,000 rows, ~300,000 changes a second | — | — | — | — | — |
| Binance tickers: ~3,100 pairs (live) | — | — | — | — | — |
| Binance order books: ~55,000 levels (live) | — | — | — | — | — |
| Sorting 1,000,000 rows by pair (~500 distinct) | — | — | — | — | — |
| Sorting 1,000,000 rows by account (nearly all distinct) | — | — | — | — | — |

Each cell: frames a second · main thread busy · longest frame gap (sorts: time to the sorted
order · whether the screen kept drawing).

## Layout of the repository

- `Mac/`: the Mac app (`project.yml`, `GinghamBench.xcodeproj`, `GinghamBench/`):
  `App/` (launch arguments, window, window mode), `Engines/` (one file per engine), `Scenarios/`
  (the generator, the stores), `Binance/` (connection, decoding, book sync), `Data/` (columns,
  formatting, the apps' sorting), `Measure/` (meter, runner, report).
- `iOS/`: the iPhone and iPad app (below).
- `Shared/BenchKey.swift`: the license key for the bench's bundle id.
- `Scripts/run-all.sh`: build and run everything on the Mac; `Scripts/release.sh`: the
  maintainer's script that makes the notarized download.
- `results/`: published results (JSON lines and their tables).

## iPhone and iPad

`iOS/` is an app for iPhone and iPad (iOS 17 or later) that shows the same live table in five
engines (Gingham, UITableView, UICollectionView, SwiftUI Table and List) and measures how smoothly
each scrolls while values change. Its setup, measurement and the device script are described in
[`iOS/README-section.md`](iOS/README-section.md).

## License

This repository is under the [MIT License](LICENSE). Gingham itself isn't open source: it's
free for tables of up to 10,000 rows, see its
[licensing](https://github.com/digitalglobeby/Gingham/blob/main/LICENSING.md).
