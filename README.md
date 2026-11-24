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
`https://github.com/digitalglobeby/Gingham` (`from: "1.1.3"`). It's free for tables of up to
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
`--load-timeout 30`, `--binance-domain binance.us`, `--window 1000x640` (also larger than the
screen: `--window 3840x2160`), `--screen LG` (the display to open on), `--gingham-extras`,
`--swiftui-diff-moves`, `--summarize file.jsonl`, `--check-formats`, `--calibrate-feed trades`,
and, in window mode, `--show order-book/collection` and `--cycle 7` (switches engines every
7 seconds, for recording). All of them are described in
[`Options.swift`](Mac/GinghamBench/App/Options.swift).

**From source**: Xcode 26 or later, then either open `Mac/GinghamBench.xcodeproj` and run the
`GinghamBench` scheme (it runs the Release configuration), or let the script build Release and
run everything:

```sh
Scripts/run-all.sh                            # 8 scenarios × 7 engines × 3 runs of 10 s + a screen pass, about 90 minutes
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
| `wide-trades` | 20,000 trades, 24 columns | ~44,800 a second | by amount, descending | generated, fixed seed |
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
- `wide-trades`: the same trades as a trading terminal shows them, with 24 columns about 2,000
  points wide (venue, account, side, status, price, bid, ask, spread, mid, last size, amount, open,
  high, low, change, change %, VWAP, volume, notional, trades, time, fee). The same generator, seed
  and rates as `live-trades` (about 44,800 row changes a second, sorted by amount); a changed trade
  gets new values in its price-related columns, 1% of them a new status. In the default window
  only the first columns are in view; at 2040 × 1080 all 24 are.
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
they hardly ever change, so this scenario shows about 0 frames with new data for every engine, and what
it measures is the cost of keeping 58,000 levels sorted while the books change (main thread busy,
data age, updates applied). **Numbers vary** with the market, the
time of day and the network; compare engines within one session. Data doesn't arrive at every
screen refresh, so even an engine that keeps up shows fewer updates a second than the refresh
rate. Binance allows 6,000 request weight a minute per IP and bans IPs that go over, so the runs
check the weight used and wait for the next minute when their requests wouldn't fit. Each request
is tried 4 times when the network fails; a run that still gets no answer is reported as the
network's failure ("network: timed out"), not the engine's, and its scenario is to be run again. Where
`binance.com` is closed, use `--binance-domain binance.us`.

**`sort-text`** and **`sort-text-account`** are a static table of 1,000,000 trades, sorted by a
text column as a click on its header sorts it: by pair (about 500 distinct pairs, the busiest far
more frequent, as in the first measurement) or by account (nearly every row a different name with
a number, like "Zürich Partners 48213"). Each run's process sorts three times, each from the
unsorted order: by its column (the first sort in the process, cold), by the other text column, by
its column again (a repeated sort, which what a table or app kept from the first may speed up:
the tuned engines keep each sorted column's keys, below); the results show the three apart. Text is
sorted in Finder's order (`localizedStandardCompare`: numbers by value, case and accents as
Finder does), and each run checks that the order shown is Finder's all the way down.

## Engines

Every engine reads the same store (the rows by column, kept on the main thread), shows the same
columns with the same widths on the screen (a column's width and 6 points of spacing: NSTableView's
and the collection view's intercell spacing; Gingham's columns get the spacing in their width,
SwiftUI's their width less its 17-point spacing, so every engine shows the same columns in the
same places), the same text for each value (numbers with grouping separators and
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
the feed.) The values a sort asks for are read as the tuned engines' sorts read the store: a
row's sort value (`sortValueFor`) is one read (a static table's text column is taken from the store
once, as the tuned engines take it), a range of rows' numbers is copied from the column's array in
one call; whatever Gingham itself keeps between sorts is its own. Its rows are drawn by the GPU.
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
  than one, 8 threads slower than one). The keys of a static table's last 4 sorted columns (each
  row's key and the distinct texts' ranks) are kept, as an expert app keeps what costs most and
  stays right while the rows don't change: sorting by a column again only sorts the rows by them.
  The finished orders aren't kept. The other tuned engines (cell-based, NSCollectionView, SwiftUI
  tuned) sort the same way; the typical NSTableView and SwiftUI Table sort from scratch every time.

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
over all of them, in an order that changes from round to round (a balanced Latin square: over the
rounds every engine runs right after each of the others about equally often, so none always
follows the same heavy one). After each run the next waits until the window server is back near
its idle CPU and GPU rates (at least 3 seconds, at most 30), so a run doesn't start while the last
one's window is still being torn down; each result records the engine before it and the wait. A run makes the scenario's rows (not measured), shows the engine's table in the
window, waits until the table has its rows, starts the feed, waits the warm-up (3 seconds, 5 for
Binance) and measures for `--seconds` (10). Everything is recorded with timestamps and
summarized over that window afterwards; a watchdog thread writes the result if the main thread
never comes back.

Frames are counted by a `CADisplayLink` of the window's screen, asked for the screen's full rate:
its callbacks run on the main thread, once per screen refresh when the main thread is free to take
it. Each callback applies the changes that came since the last one (above). Per engine:

- **Frames with new data a second (max = the display's rate)**: how many times a second the table's
  picture actually changed (at least one visible value new): like frames a second, but a frozen
  table scores 0, not the display's rate (120 on a MacBook Pro, 60 on most external displays). What the eye sees, measured from outside every engine. The
  app captures its own window with ScreenCaptureKit (only that window, at up to the display's
  rate, at half its size in points, on a background queue); it gets a frame whenever the window's
  content changed, and a frame counts when the table's body changed: its pixel rows are compared
  with the previous frame's (the rectangles ScreenCaptureKit reports as changed cover the whole
  window), leaving out the top bar with its live numbers, the column header and the scroller
  strips. Also the median share of the table's rows that changed in one. The headline number.
  Data that changes off the screen changes no pixels: on `live-trades`, sorted by amount, only
  about 60% of the frames' changes reach the rows in view, so about 70–75 frames with new data a
  second is all any engine can show there; on the feeds whose busiest rows are in view, nearly every update
  shows. The capture itself tops out near 110 frames a second (it saw 110.6 of the 119.4 frames
  Gingham presented on `order-book`).
  It needs the **Screen Recording permission** of the process that captures: the app's when it's
  opened from the Finder, the terminal app's when it runs from the command line (System Settings ›
  Privacy & Security › Screen & System Audio Recording). Without it the column says why it's
  empty. Measured cost (the 2026-11-23 default-size session, Gingham 1.1.1): none for Gingham and the cell-based
  table (119.3 updates applied a second against 119.4, 119.8 against 119.7 on `order-book`), up to
  about 10% fewer updates for the saturated view-based engines (NSCollectionView on `order-book`
  51.7 against 57.3, the tuned NSTableView 52 against 56.5); so `run-all.sh`
  measures without it and runs one more round of every scenario and engine with it
  (`--separate-screen-pass`), whose screen numbers fill the column. Each sort run also checks the
  meter: two seconds after the sorts, with nothing changing, should give about 0 frames with new data
  while the callbacks go on. `GINGHAM_BENCH_VISIBLE_TRUTH=1` adds the data's own answer on
  `live-trades`: the callbacks after which the 30 top rows by amount look different
  (`visibleDataChangesPerSecond`), and whether the engine shows exactly those rows in that order
  one frame later (printed after the run); `=26` counts the top 26 rows instead of 30. Checked
  that way in an earlier session (not in the results; 26 rows, about those in the
  meter's region for every engine): Gingham 72.5 frames with new data a second against 69.5 data
  changes, the tuned NSTableView 58.8 against 59.5, the cell-based one 68.3 against 69.8.
- **System frames a second (trace)**: the system's own count, from an Instruments trace of one more
  run of each engine on `live-trades` and `order-book` (`--trace-pass`, also through `run-all.sh`;
  only the Hitches and Display instruments: in a test, the whole Animation Hitches template slowed
  the traced run to 60 frames a second). No trace table is per window on macOS (the display's "Displayed
  Surfaces" are the whole screen's framebuffers), but two are per process: the Core Animation
  commits that went into a display frame (`hitches-updates`, with the frame's swap ID) and the GPU's
  accesses to surfaces (`metal-io-surface-access`), the window server's reads included: Gingham's
  table is drawn by the GPU, and its frames show up there. The column counts the display frames that got new content
  from the bench's window either way, once each. During that run the top bar's live numbers stay
  still, so the commits are the table's. Instruments attaches to the run's process
  (`xctrace record --attach`): launched by `xctrace --launch`, a binary inside an app bundle goes
  through Launch Services, which may start another copy of the app with the same bundle id. Each
  trace (10 seconds at most) is read right after it's recorded and deleted, with the raw kernel
  trace Instruments leaves behind in the temporary folder (`instruments*.ktrace`, 1–2 GB each), one
  on the disk at a time, in `~/Library/Caches/gingham-bench-traces`; the pass stops with less than 40 GB free.
  What it showed (the 2026-11-23 default-size session, Gingham 1.1.1, one traced run each): Gingham's GPU frames
  the window server read equal its own presented frames (119.75 and 119.75 on `live-trades`, 118.5
  and 118.5 on `order-book`); for the AppKit engines the display frames with new content equal the
  updates applied when every update changes something in view (`order-book`: the tuned NSTableView
  50.5 and 50.5, NSCollectionView 51 and 51), and are fewer when not (`live-trades`: the tuned
  NSTableView 54.5 of 90.5 updates applied, against 49.5 frames with new data). It is an upper bound of
  what changes on the screen: a frame with the same pixels counts too (Gingham presents a frame for
  every batch applied: 119.5 such frames a second on `live-trades` against 73.3 with new data; the
  cell-based table 73 against 58.8, its GPU frames 85.8). The screen numbers come from runs without
  a trace.
- **Updates applied a second**: callbacks that applied new data, the times a second the table was
  given something new to show (at most the screen's refresh rate). Whether each update then
  reached the screen, only Gingham can tell (`GHTableView.framePresented`); its **frames
  presented** a second are shown next to it. No other engine has a way to report that. The window's
  big number is the frames with new data when the meter runs, and these otherwise.
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
  shown, nothing changing; it composites every app's layers, so this is Mac-wide; that idle rate is
  shown next to it, per run in the JSON and the log: a high one, or one far from the other runs'
  means the screen wasn't quiet, and the window server's numbers compare only within a quiet
  session), and **the two
  together**: the work lands in different places, AppKit's drawing composited under the window
  server, Gingham's GPU work counted as the process's. Only increases between samples count (a GPU client that
  closes takes its time with it). Also the process's **CPU energy** as the kernel accounts it
  (`task_energy` of `TASK_POWER_INFO_V2`): the CPU's alone, not the GPU work the process does
  (Gingham's table is drawn by the GPU), not the window server's compositing (AppKit's drawing is
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
  measuring, for every engine alike, and saves no window state (`isRestorable = false`, no
  `ApplePersistence`): AppKit would write it about 11 seconds into a run, holding the main thread
  15–20 ms.
- **The window's size** decides how many cells are in view, the work every view-based engine does
  per frame: 1000 × 640 points of table by default, the same for all (`--window`). Each run records
  the rows and columns the engine laid out for its window (NSTableView's rows and columns in its
  visible rect, also the one SwiftUI's Table is made of, the collection view's visible items,
  Gingham's visible rows and columns).
- **A window larger than the screen**: `--window 3840x2160` on a MacBook (2056 × 1329 points) is a
  3840 × 2160-point table, larger than the MacBook's screen: what a 4K display at 120 Hz would
  show. The window keeps that size (AppKit would shrink it to the screen) with its top left at the
  screen's, and every engine lays out and draws all of it (107 rows by 8 columns of `live-trades`,
  SwiftUI's taller rows 89, the screen showing about a third). ScreenCaptureKit captures the whole
  window, the part off the screen too, but at this size the capture is costly (Gingham's 120 updates
  applied a second fell to 60 with it), so there the numbers to read are Gingham's presented frames,
  the updates applied, main thread busy and data age; the window server's GPU rate with nothing
  changing is high at this size (about 85 ms a second), so its GPU column isn't comparable either.
  A real 4K display at 60 Hz gives the same picture at half the rate.
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

Measured on 2026-11-24 with `Scripts/run-all.sh` (3 runs of 10 s each, medians) on a MacBook Pro
(MacBookPro18,2, Apple M1 Max, 10 cores, 32 GB), macOS 27.2.1, Gingham 1.1.3, Release build: on
the built-in display at 120 Hz in its "More Space" mode (2056 × 1329 points at 2×), and on an LG
UltraFine 4K at 60 Hz (3840 × 2160 points at 1×). The full tables (every column, lowest and
highest of the runs) and the raw JSON lines:

- built-in display: [default window](results/2026-11-24-0906.md) ([JSON](results/2026-11-24-0906.jsonl)),
  [2040 × 1080](results/2026-11-24-1037.md) ([JSON](results/2026-11-24-1037.jsonl)),
  [3840 × 2160](results/2026-11-24-1456.md) ([JSON](results/2026-11-24-1456.jsonl)) and its
  [second set](results/2026-11-24-1215.md) ([JSON](results/2026-11-24-1215.jsonl));
- the 4K display: [3700 × 1890](results/2026-11-24-1258.md) ([JSON](results/2026-11-24-1258.jsonl)),
  [3840 × 2160](results/2026-11-24-1345.md) ([JSON](results/2026-11-24-1345.jsonl)), the cell-based
  table's live trades [again](results/2026-11-24-1648.md) ([JSON](results/2026-11-24-1648.jsonl)).

What changed since the first results (2026-11-23, Gingham 1.1.1, in `results/2026-11-23-*`): the
engines run in a balanced order that changes from round to round, and each run waits for the
window server to settle after the one before (until then Gingham always ran right after the tuned
SwiftUI Table, often stuck and killed with a huge window to tear down); each run records the window
server's idle GPU rate, so a screen that wasn't quiet shows; Binance requests are retried and a
network failure is reported as such; every engine's columns take the same room on the screen;
sorts are timed cold and repeated; no window state is saved during runs; and `wide-trades` is new.
The balanced order and the settle wait came in during the day: the default-window and 2040 × 1080
sets ([0906](results/2026-11-24-0906.md), [1037](results/2026-11-24-1037.md)) still ran in the
fixed order with a 1-second pause and no settling (their runs have no `settleSeconds`); the
3840 × 2160 and 4K-display sets (1215 on) ran with both. The tables below are made from the
results files by `Scripts/readme-tables.py` (medians, rounded as the app's own tables round).

**Frames with new data a second (max = the display's rate)**: how many times a second the table's
picture actually changed (at least one visible value new); like frames a second, but a frozen
table scores 0, not the display's rate. Measured from outside every engine (the window's pixels).

### Live data, the default window (1000 × 640 points of table, 2000 × 1280 pixels)

Frames with new data a second (max = the display's rate, 120) · main thread busy · data age
(median, from the change to the frame that applied it). "stuck": the main thread didn't come back
within 15 seconds after the measured window.

<!-- table: default -->
| Engine | Live trades: 20,000 rows, ~44,800 changes/s | Wide live trades: the same, 24 columns | Order book: 200,000 rows, ~243,500 changes/s | Trade feed: 1,000,000 rows, ~300,000 changes/s |
| --- | --- | --- | --- | --- |
| Gingham | 73 · 35% · 4 ms | 74 · 39% · 4 ms | 108 · 35% · 5 ms | 108 · 27% · 6 ms |
| NSTableView | 42 · 96% · 12 ms | 21 · 96% · 25 ms | 19 · 99% · 27 ms | 10 · 99% · 49 ms |
| NSTableView, tuned | 50 · 68% · 8 ms | 34 · 90% · 13 ms | 51 · 98% · 10 ms | 40 · 98% · 14 ms |
| NSTableView, cell-based | 62 · 40% · 4 ms | 56 · 50% · 6 ms | 82 · 91% · 5 ms | 92 · 86% · 6 ms |
| NSCollectionView | 50 · 68% · 8 ms | 33 · 91% · 13 ms | 51 · 98% · 10 ms | 41 · 98% · 14 ms |
| SwiftUI Table | 1 · 100% · 5,035 ms (2 of 3 runs; 1 stuck) | 0 · 100% · 6,188 ms | stuck | stuck |
| SwiftUI Table, tuned | 4 · 100% · 138 ms | 1 · 100% · 465 ms | stuck | 0 · 100% · 5,926 ms |
<!-- /table -->

On the trades, sorted by amount, only about 60% of the frames' changes reach the rows in view, so
about 70–75 frames with new data a second is all any engine can show there; Gingham and the
cell-based NSTableView apply every frame's changes (120 updates applied a second on all four), the
others fewer. On the order book and trade feed nearly every update shows, up to the screen
capture's ceiling of about 110 a second. On the wide trades NSCollectionView filled the labels of
all 24 columns in its items while the other engines made only the 13 columns in view
(`renderedColumns` in the JSON lines), more work for it; from the next session it fills only the
columns in view, as the others do.

### Live data, a large window (2040 × 1080 points of table, 4080 × 2160 pixels)

From here on the screen capture can't tell an engine at 110 from one at 120 (it tops out near 110
frames a second) and the trace slows the runs it records, so: Gingham's presented frames (exact,
counted by Gingham, matching the system's trace at the default size) or, for the others, the
updates applied a second (the most an engine can have shown) · main thread busy · data age. The
full tables have the meter's and the trace's columns too.

<!-- table: large -->
| Engine | Live trades | Wide live trades | Order book | Trade feed |
| --- | --- | --- | --- | --- |
| Gingham | 120 presented · 38% · 4 ms | 120 presented · 39% · 5 ms | 120 presented · 33% · 5 ms | 120 presented · 43% · 6 ms |
| NSTableView | 27 applied · 96% · 21 ms | 10 applied · 98% · 54 ms | 10 applied · 99% · 52 ms | 4 applied · 100% · 116 ms |
| NSTableView, tuned | 49 applied · 93% · 12 ms | 13 applied · 97% · 38 ms | 31 applied · 97% · 17 ms | 15 applied · 98% · 36 ms |
| NSTableView, cell-based | 113 applied · 77% · 6 ms | 43 applied · 97% · 13 ms | 76 applied · 97% · 7 ms | 40 applied · 95% · 15 ms |
| NSCollectionView | 49 applied · 93% · 12 ms | 13 applied · 97% · 39 ms | 32 applied · 97% · 17 ms | 14 applied · 97% · 36 ms |
| SwiftUI Table | stuck | stuck | stuck | stuck |
| SwiftUI Table, tuned | 2 applied · 100% · 240 ms | 1 applied · 100% · 3,728 ms | stuck | 0 applied · 100% · 5,929 ms |
<!-- /table -->

### Live data, larger than the MacBook's screen (3840 × 2160 points of table, 7680 × 4320 pixels)

A 3840 × 2160-point table, larger than the MacBook's screen: what a 4K display at 120 Hz would
show. Every engine lays out and draws all of it (107 rows of 20 points, SwiftUI's taller rows 89;
the screen shows the top left). Presented (Gingham) or applied (the others) · main thread busy · data age.

<!-- table: macbook-4k -->
| Engine | Live trades | Wide live trades | Order book | Trade feed |
| --- | --- | --- | --- | --- |
| Gingham | 120 presented · 26% · 4 ms | 116–120 presented · 50–68% · 4–6 ms | 115–120 presented · 44–67% · 5 ms | 120 presented · 79% · 6 ms |
| NSTableView | 14 applied · 97% · 37 ms | 5 applied · 99% · 104 ms | 4 applied · 100% · 115 ms | 2 applied · 100% · 264 ms |
| NSTableView, tuned | 19 applied · 97% · 28 ms | 6 applied · 99% · 84 ms | 16 applied · 96% · 31 ms | 7 applied · 99% · 75 ms |
| NSTableView, cell-based | 40 applied · 98% · 14 ms | 17 applied · 99% · 31 ms | 37 applied · 99% · 14 ms | 20 applied · 99% · 28 ms |
| NSCollectionView | 19 applied · 97% · 29 ms | 6 applied · 99% · 84 ms | 16 applied · 96% · 32 ms | 7 applied · 99% · 73 ms |
| SwiftUI Table | stuck | stuck | stuck | stuck |
| SwiftUI Table, tuned | 1 applied · 100% · 1,031 ms | 0 applied · 100% · 4,479 ms | stuck | 0 applied · 100% · 5,995 ms |
<!-- /table -->

Gingham's wide trades and order book differ between the two sets measured the same way: 116 and
115 presented at 68% and 67% busy in one ([1456](results/2026-11-24-1456.md)), 120 and 120 at 50%
and 44% in the other ([1215](results/2026-11-24-1215.md)); hence the ranges.

### Live data on a 4K display at 60 Hz (LG UltraFine, 3840 × 2160 points at 1×)

Presented (Gingham) or applied (the others), at most 60 · main thread busy · data age. A table
filling the display (3700 × 1890 points):

<!-- table: display-4k-fill -->
| Engine | Live trades | Wide live trades | Order book | Trade feed |
| --- | --- | --- | --- | --- |
| Gingham | 60 presented · 28% · 8 ms | 60 presented · 33% · 8 ms | 60 presented · 31% · 9 ms | 60 presented · 42% · 10 ms |
| NSTableView | 15 applied · 93% · 34 ms (2 of 3 runs; 1 invalid) | 5 applied · 98% · 93 ms | 5 applied · 99% · 101 ms | 2 applied · 99% · 233 ms |
| NSTableView, tuned | 21 applied · 94% · 25 ms (2 of 3 runs; 1 invalid) | 6 applied · 97% · 79 ms | 18 applied · 97% · 29 ms | 7 applied · 98% · 69 ms |
| NSTableView, cell-based | 59 applied · 89% · 10 ms (2 of 3 runs; 1 invalid) | 22 applied · 97% · 25 ms | 52 applied · 98% · 11 ms | 22 applied · 98% · 24 ms |
| NSCollectionView | 21 applied · 93% · 25 ms (2 of 3 runs; 1 invalid) | 7 applied · 98% · 75 ms | 17 applied · 93% · 29 ms | 8 applied · 96% · 65 ms |
| SwiftUI Table | stuck | stuck | stuck | stuck |
| SwiftUI Table, tuned | 1 applied · 100% · 467 ms | 0 applied · 100% · 6,097 ms | stuck | 0 applied · 100% · 6,226 ms |
<!-- /table -->

("invalid": the window was covered during the run.) And 3840 × 2160 points, a little larger than
that display (3840 × 2130 points of it on the screen); the cell-based table's live trades from
[a run of its own](results/2026-11-24-1648.md), its runs in the set having been covered:

<!-- table: display-4k -->
| Engine | Live trades | Wide live trades | Order book | Trade feed |
| --- | --- | --- | --- | --- |
| Gingham | 60 presented · 28% · 8 ms | 60 presented · 33% · 8 ms | 60 presented · 32% · 9 ms | 60 presented · 45% · 10 ms |
| NSTableView | 14 applied · 93% · 38 ms | 5 applied · 98% · 104 ms | 4 applied · 99% · 114 ms | 2 applied · 99% · 262 ms |
| NSTableView, tuned | 18 applied · 93% · 29 ms | 6 applied · 98% · 87 ms | 16 applied · 96% · 32 ms | 6 applied · 98% · 76 ms |
| NSTableView, cell-based | 56 applied · 95% · 10 ms | 19 applied · 98% · 27 ms | 48 applied · 98% · 11 ms | 20 applied · 97% · 27 ms |
| NSCollectionView | 19 applied · 93% · 29 ms | 6 applied · 98% · 84 ms | 16 applied · 94% · 32 ms | 7 applied · 97% · 73 ms |
| SwiftUI Table | stuck | stuck | stuck | stuck |
| SwiftUI Table, tuned | 1 applied · 100% · 906 ms | 0 applied · 100% · 4,450 ms | stuck | 0 applied · 100% · 6,031 ms |
<!-- /table -->

### Sorting 1,000,000 rows by a text column

Each run's process sorts three times, each from the unsorted order: its column (the first sort,
cold), the other text column, its column again (a repeated sort). Time to the sorted order on the
screen, cold · repeated · longest stall of the cold sort (the screen kept drawing when it stays
near 8 ms). By pair has about 500 distinct texts, by account nearly a million. The tuned engines
keep a static table's sorted columns' keys, the typical ones sort from scratch.

<!-- table: sorts -->
| Engine | By pair | By account |
| --- | --- | --- |
| Gingham | 0.07 s · 0.01 s · 17 ms | 0.19 s · 0.02 s · 17 ms |
| NSTableView | 5.17 s · 5.22 s · 5,173 ms | 7.98 s · 7.96 s · 7,985 ms |
| NSTableView, tuned | 0.09 s · 0.13 s · 17 ms | 7.91 s · 0.08 s · 21 ms |
| NSTableView, cell-based | 0.09 s · 0.04 s · 8 ms | 7.90 s · 0.07 s · 17 ms |
| NSCollectionView | 0.11 s · 0.07 s · 25 ms | 7.90 s · 0.10 s · 31 ms |
| SwiftUI Table | no sorted order within 60 s | no sorted order within 60 s |
| SwiftUI Table, tuned | 0.94 s · 0.88 s · 838 ms | 13.19 s · 0.91 s · 892 ms |
<!-- /table -->

### Binance (live market: numbers vary)

Tickers (about 3,100 pairs, sorted by trades): frames with new data a second (max = the
display's rate, 120) · main thread busy · data age (from arrival).

The order books (about 55,000 levels of 6 pairs, sorted by pair and then price, highest first)
show the top of the first pair's asks, 5,000 levels away from the market: those rows hardly ever
change, so every engine shows 0 frames with new data there, and what this scenario measures is
the cost of keeping the levels sorted while the books change: updates applied · main thread busy ·
data age. (Gingham presents a frame only when something in view changed: 12 a second of its 28
updates.)

<!-- table: binance -->
| Engine | Tickers | Order books |
| --- | --- | --- |
| Gingham | 67 · 17% · 4 ms | 28 applied · 8% · 4 ms |
| NSTableView | 31 · 84% · 12 ms | 10 applied · 95% · 35 ms |
| NSTableView, tuned | 53 · 21% · 4 ms | 28 applied · 23% · 5 ms |
| NSTableView, cell-based | 63 · 27% · 4 ms | 24 applied · 14% · 4 ms |
| NSCollectionView | 58 · 21% · 4 ms | 26 applied · 14% · 5 ms |
| SwiftUI Table | 25 · 86% · 13 ms | 1 applied · 100% · 608 ms |
| SwiftUI Table, tuned | 24 · 59% · 8 ms | 5 applied · 100% · 106 ms |
<!-- /table -->

### iPhone

iPhone 15 Pro Max (iPhone16,2), iOS 27.2.1, Gingham 1.1.3, 120 Hz, Release build, 2026-11-24; the
JSON summaries are in [`results/ios`](results/ios) (`*-2026-11-24-185915.json`).

Instruments' Animation Hitches on the device (the primary render-side figure: everything that made
a frame late, wherever the work happened; one recording per engine while the app runs its tests at
100,000 rows and 1,000 changes a second): hitch time, ms a second, in the steady · fast · flick
scrolling tests.

| Engine | Steady | Fast | Flicks |
| --- | --- | --- | --- |
| Gingham | 0 | 3.6 | 6.2 |
| UITableView (typical) | 501.3 | 506.4 | 501.2 |
| UITableView (tuned) | 2.1 | 1.0 | 6.2 |
| UICollectionView (typical) | 2.1 | 1.0 | 0 |
| UICollectionView (tuned) | 2.1 | 2.1 | 2.1 |
| SwiftUI List | 1.6 | 3.1 | 4.2 |

Under 5 ms a second is good, over 10 bad (Apple's guidance). The app's own meter (secondary: the
main thread's frame callbacks, which can't see work done after the main thread hands a frame over),
flick test, median of 3 runs: frames a second · main thread busy.

| Engine | 100,000 rows, 1,000 changes/s | 1,000,000 rows, 10,000 changes/s |
| --- | --- | --- |
| Gingham | 120 · 19% | 120 · 29% |
| UITableView (typical) | 62.4 · 80% | 7.0 · 99% |
| UITableView (tuned) | 120 · 40% | 120 · 41% |
| UICollectionView (typical) | 120 · 43% | 120 · 41% |
| UICollectionView (tuned) | 120 · 39% | 120 · 41% |
| SwiftUI List | 120 · 40% | 120 · 41% |

XCUITest flicks (UIKit's own scroll metric, five flicks each; the 2026-11-23 run, Gingham 1.1.1,
[`ios-flicks-2026-11-23-104601.json`](results/ios/ios-flicks-2026-11-23-104601.json)): no hitches
and 116–119 frames a second for every engine (Gingham 117.6, UITableView tuned 119.0,
UICollectionView typical 116.0 and tuned 118.7, SwiftUI List 117.3; medians of the five flicks)
except the typical UITableView: a median of 294 hitches a flick, a hitch time ratio of 72.5 ms a
second, 111.1 frames a second.

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
  script that pushes main and makes the release; `Scripts/next-session.sh`: a whole measurement
  session, unattended; `Scripts/readme-tables.py`: the README's Results tables, made from the
  results files (`--check` tells whether they still match).

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
