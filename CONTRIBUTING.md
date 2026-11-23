# Contributing

This bench exists so that anyone can check Gingham's claims, so the most useful contributions make
the **other** engines faster: if you know a better way to use NSTableView, NSCollectionView or
SwiftUI's Table for live data, show it, and it will be measured and published, whatever it does
to Gingham's lead.

## Making an engine faster

- Each engine is one file in [`Mac/GinghamBench/Engines`](Mac/GinghamBench/Engines) (the tuned
  AppKit engines share `TunedRows.swift` and the sorting in `Data/AppSort.swift`). Change an
  existing engine, or add one next to it (a case in `EngineKind`) if it's a different approach
  that stands on its own.
- Keep the rules every engine follows: the same store, columns, widths and text for each value
  (`--check-formats`), everything the feed sends applied at every display-link callback, the
  order check after the run passing, no work hidden from the measurement (a background thread is
  fine: process CPU and GPU are reported too).
- Hot closures and loops go into `nonisolated` helpers (see the comment in `Data/AppSort.swift`);
  `Scripts/check-isolation.sh` fails otherwise.
- Explain each choice in a comment, as the existing engines do, and update the engine's section
  of the README.

## Before/after numbers

Every pull request that changes an engine or the measurement includes numbers from
`Scripts/run-all.sh` (Release build, a quiet Mac on power, Low Power Mode off, the window on the
built-in display), before and after, from the same Mac and session:

```sh
git stash; Scripts/run-all.sh --scenario live-trades,order-book --engine nstable-tuned; git stash pop
Scripts/run-all.sh --scenario live-trades,order-book --engine nstable-tuned
```

Paste both Markdown tables (`results/<date>.md`) into the pull request, with the Mac's model,
chip, macOS version and display (the first line of the table).

## Other changes

Fixes to the measurement, new scenarios with real-world shapes, and corrections to the README are
welcome too. The Gingham engine uses only Gingham's public API; questions about Gingham itself go
to [its repository](https://github.com/digitalglobeby/Gingham).

By contributing you agree that your contribution is licensed under the MIT License of this
repository.
