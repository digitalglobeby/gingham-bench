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
