#!/usr/bin/env python3
"""The README's Results tables, made from the results files (never typed by hand).

Each table in README.md sits between `<!-- table: NAME -->` and `<!-- /table -->`; this script
replaces what is between them with the table made from the results it cites, rounded as the app's
own Markdown (Report.swift) rounds: to the nearest and ties to even.

A table may cite several sets (results files) of the same measurement, e.g. those of
`Scripts/next-session.sh --sets 3`: each number is then the median of the sets' medians, with the
lowest and highest of the sets' medians in brackets ("46% (44–87)"); with one set, the median of
its runs (and, where a table says so, the lowest and highest of its runs in brackets).

Tables listed in PENDING are made only where the README has their markers: they wait for the
results of the next session (put the set's file into their list, and the markers into the README).

    python3 -I Scripts/readme-tables.py           rewrites README.md
    python3 -I Scripts/readme-tables.py --check   exits 1 if README.md isn't what the files give
"""

import json
import re
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "results"
ENGINES = ["gingham", "nstable", "nstable-tuned", "nstable-cells", "collection", "swiftui", "swiftui-tuned", "swiftui-slots"]
LIVE = [("live-trades", "Live trades"), ("wide-trades", "Wide live trades"),
        ("order-book", "Order book"), ("trade-feed", "Trade feed")]

_cache = {}


def runs(name):
    if name not in _cache:
        _cache[name] = [json.loads(line) for line in (RESULTS / name).read_text().splitlines() if line.strip()]
    return _cache[name]


def number(value, digits=0):
    """As Swift's `.number.precision(.fractionLength(digits)).grouping(.automatic)`: ties to even."""
    rounded = round(value, digits)
    return f"{rounded:,.{digits}f}"


def median(values):
    return statistics.median(values) if values else None


def title(engine, names):
    for name in names:
        for run in runs(name):
            if run["engine"] == engine:
                return run["engineTitle"]
    return engine


def has_runs(names, engine):
    return any(r["engine"] == engine for name in names for r in runs(name))


def measured(name, scenario, engine):
    """The measured runs (no screen or trace pass), and those that ended ok with numbers."""
    every = [r for r in runs(name) if r["scenario"] == scenario and r["engine"] == engine and not r.get("pass")]
    return every, [r for r in every if r["status"] == "ok" and (r.get("numbers") or r.get("sorts"))]


def screen_runs(name, scenario, engine):
    """Runs with the screen meter's numbers (the screen pass; not traced runs)."""
    return [r for r in runs(name) if r["scenario"] == scenario and r["engine"] == engine and r.get("pass") != "trace"
            and r["status"] == "ok" and (r.get("numbers") or {}).get("screenUpdatesPerSecond") is not None]


def failed(every, ok):
    """'stuck', or a note on the runs that failed (empty: none did)."""
    bad = [r for r in every if r not in ok]
    if not bad:
        return ""
    statuses = sorted({r["status"] for r in bad})
    if not ok:
        return " / ".join(statuses)
    return f" ({len(ok)} of {len(every)} runs; {len(bad)} {' / '.join(statuses)})"


def stat(names, scenario, engine, pick, across="sets", select=measured):
    """(median, lowest, highest) of a number over the sets (each set's median of its runs), or with
    `across="runs"` and one set, over its runs; None if no run has it."""
    per_set, all_values = [], []
    for name in names:
        chosen = select(name, scenario, engine)
        ok = chosen[1] if isinstance(chosen, tuple) else chosen
        values = [v for v in (pick(r) for r in ok) if v is not None]
        if values:
            per_set.append(median(values))
            all_values += values
    if not per_set:
        return None
    spread = all_values if across == "runs" and len(names) == 1 else per_set
    return median(per_set), min(spread), max(spread)


def show(value, digits=0, suffix="", ranges=True):
    """"46%" or "46% (44–87)": the range when it rounds to more than one number."""
    if value is None:
        return "—"
    middle, low, high = value
    text = number(middle, digits) + suffix
    if ranges and number(low, digits) != number(high, digits):
        text += f" ({number(low, digits)}–{number(high, digits)})"
    return text


def note(names, scenario, engine):
    """The sets' failure note ("stuck", " (2 of 3 runs; 1 invalid)", "" when none failed), or None
    when a set has no runs of the engine."""
    notes = []
    for name in names:
        every, ok = measured(name, scenario, engine)
        if not every:
            return None
        notes.append((failed(every, ok), bool(ok)))
    if not any(has for _, has in notes):
        return " / ".join(sorted({n for n, _ in notes}))
    marks = [n for n, has in notes if n and has]
    if len(names) == 1:
        return marks[0] if marks else ""
    return " (runs failed in some sets)" if marks or not all(has for _, has in notes) else ""


def numbers(key, scale=1):
    return lambda r: None if (r.get("numbers") or {}).get(key) is None else r["numbers"][key] * scale


# MARK: Live tables

def live_cell(names, scenario, engine, kind):
    """`screen`: frames with new data · busy · data age (the default window); `updates`: Gingham's
    presented frames or the others' updates applied · the screen pass · busy · data age."""
    status = note(names, scenario, engine)
    if status is None:
        return "—"
    busy = stat(names, scenario, engine, numbers("busyShare", 100))
    if busy is None:
        return status
    age = show(stat(names, scenario, engine, numbers("dataAgeP50Ms")), ranges=False)
    screen = stat(names, scenario, engine, numbers("screenUpdatesPerSecond"), select=screen_runs)
    if kind == "screen":
        return f"{show(screen, ranges=False)} · {show(busy, suffix='%')} · {age} ms{status}"
    presented = stat(names, scenario, engine, numbers("presentedPerSecond"))
    updates = presented or stat(names, scenario, engine, numbers("updatesAppliedPerSecond"))
    return f"{show(updates)} · screen {show(screen, ranges=False)} · {show(busy, suffix='%')} · {age} ms{status}"


def cost_cell(names, scenario, engine):
    """Mac power (CPU + GPU) and the energy an update · process CPU · memory."""
    status = note(names, scenario, engine)
    if status is None:
        return "—"
    cpu = stat(names, scenario, engine, numbers("cpuPercent"))
    if cpu is None:
        return status
    power = stat(names, scenario, engine, lambda r: (r.get("power") or {}).get("combinedMilliwatts"))
    energy = stat(names, scenario, engine, lambda r: (r.get("power") or {}).get("millijoulesPerUpdate"))
    memory = stat(names, scenario, engine, numbers("memoryMB"))
    watts = "—" if power is None else show(tuple(v / 1000 for v in power), 2, " W") + (
        "" if energy is None else f", {show(energy, ranges=False)} mJ an update")
    return f"{watts} · {show(cpu, suffix='%')} CPU · {show(memory, ranges=False)} MB{status}"


def live_table(names, cell, scenarios=LIVE, headers=None, overrides=None):
    overrides = overrides or {}
    header = headers or [label for _, label in scenarios]
    lines = ["| Engine | " + " | ".join(header) + " |", "| --- |" + " --- |" * len(scenarios)]
    for engine in ENGINES:
        cells = [cell(overrides.get((engine, scenario), names), scenario, engine) for scenario, _ in scenarios]
        if all(c == "—" for c in cells):
            continue
        lines.append(f"| {title(engine, names)} | " + " | ".join(cells) + " |")
    return lines


def screen_table(names, **options):
    return live_table(names, lambda n, s, e: live_cell(n, s, e, "screen"), **options)


def updates_table(names, **options):
    return live_table(names, lambda n, s, e: live_cell(n, s, e, "updates"), **options)


def cost_table(names, **options):
    return live_table(names, cost_cell, **options)


def history_table(names, engine, scenarios=LIVE):
    """One engine in several sets of the same window: presented (or applied) · busy (its runs'
    lowest–highest), per set."""
    header = ["Set", "Gingham"] + [label for _, label in scenarios]
    lines = ["| " + " | ".join(header) + " |", "|" + " --- |" * len(header)]
    for name in names:
        version = next((r["machine"]["gingham"] for r in runs(name)), "?")
        cells = []
        for scenario, _ in scenarios:
            every, ok = measured(name, scenario, engine)
            presented = stat([name], scenario, engine, numbers("presentedPerSecond"))
            busy = stat([name], scenario, engine, numbers("busyShare", 100), across="runs")
            cells.append("—" if busy is None else f"{show(presented, ranges=False)} · {show(busy, suffix='%')}{failed(every, ok)}")
        lines.append(f"| [{name[:-6]}](results/{name[:-6]}.md) | {version} | " + " | ".join(cells) + " |")
    return lines


# MARK: Sorts and Binance

def sort_cell(names, scenario, engine):
    """Time to the sorted order on the screen, cold (lowest–highest) · repeated (lowest–highest) ·
    longest stall of the cold sort."""
    sorted_runs = []
    for name in names:
        every, ok = measured(name, scenario, engine)
        if not every:
            continue
        good = [r for r in ok if r.get("sorts")]
        if not good:
            if all("didn't reach the screen within 60 s" in (r.get("note") or "") for r in every):
                return "no sorted order within 60 s"
            return " / ".join(sorted({r["status"] for r in every})) or "—"
        sorted_runs += good
    if not sorted_runs:
        return "—"

    def times(step, key="seconds"):
        values = [s[key] for r in sorted_runs for s in r["sorts"] if s.get("step") == step]
        return (median(values), min(values), max(values)) if values else None
    return f"{show(times('first'), 2, ' s')} · {show(times('again'), 2, ' s')} · {show(times('first', 'longestFrameGapMs'), ranges=False)} ms"


def sort_table(names):
    lines = ["| Engine | By pair | By account | By amount (a number) |", "| --- | --- | --- | --- |"]
    for engine in ENGINES:
        if not has_runs(names, engine):
            continue
        cells = [sort_cell(names, scenario, engine) for scenario in ("sort-text", "sort-text-account", "sort-number")]
        lines.append(f"| {title(engine, names)} | " + " | ".join(cells) + " |")
    return lines


def busy_cell(names, scenario, engine):
    """Main thread busy (its runs' lowest–highest) · data age."""
    status = note(names, scenario, engine)
    if status is None:
        return "—"
    busy = stat(names, scenario, engine, numbers("busyShare", 100), across="runs")
    if busy is None:
        return status
    age = show(stat(names, scenario, engine, numbers("dataAgeP50Ms")), ranges=False)
    return f"{show(busy, suffix='%')} · {age} ms{status}"


def binance_table(names):
    lines = ["| Engine | Tickers | Order books |", "| --- | --- | --- |"]
    for engine in ENGINES:
        if not has_runs(names, engine):
            continue
        lines.append(f"| {title(engine, names)} | {busy_cell(names, 'binance-tickers', engine)} | {busy_cell(names, 'binance-books', engine)} |")
    return lines


# MARK: Where each table comes from

def sources_table(tables):
    lines = ["| Table | Set | Gingham | Bench commit | Engines' order |", "| --- | --- | --- | --- | --- |"]
    for label, names in tables:
        for name in names:
            every = runs(name)
            versions = sorted({r["machine"]["gingham"] for r in every})
            commits = sorted({r["machine"].get("benchCommit") or "not recorded" for r in every})
            order = "balanced, settled" if any(r.get("after") for r in every) else "fixed, no settling"
            lines.append(f"| {label} | [{name[:-6]}](results/{name[:-6]}.md) | {', '.join(versions)} | {', '.join(commits)} | {order} |")
    return lines


# MARK: iPhone

IOS_ENGINES = ["Gingham", "UITableView (typical)", "UITableView (tuned)", "UICollectionView (typical)",
               "UICollectionView (tuned)", "SwiftUI List"]
IOS_FILES = {"gingham": "Gingham", "tableView": "UITableView (typical)", "tableViewTuned": "UITableView (tuned)",
             "collectionView": "UICollectionView (typical)", "collectionViewTuned": "UICollectionView (tuned)",
             "swiftUIList": "SwiftUI List"}


def ios_number(value):
    return number(value, 0) if float(value).is_integer() else number(value, 1)


def ios_hitches_table(stamp):
    """Hitch time, ms a second, steady · fast · flicks: the median of the recordings (a combined
    `ios-hitches-<stamp>.json`, run-device.sh's three a engine), or each engine's one recording."""
    combined = RESULTS / "ios" / f"ios-hitches-{stamp}.json"
    values = {}
    if combined.exists():
        for test in json.loads(combined.read_text())["tests"]:
            values[(test["engine"], test["test"])] = test["medianHitchTimeMsPerSecond"]
    else:
        for key, engine in IOS_FILES.items():
            path = RESULTS / "ios" / f"ios-hitches-{key}-{stamp}.json"
            if path.exists():
                for test in json.loads(path.read_text())["tests"]:
                    profile = test["test"].split(" run ")[0].rsplit(" ", 1)[-1]
                    values[(engine, profile)] = test["hitchTimeMsPerSecond"]
    lines = ["| Engine | Steady | Fast | Flicks |", "| --- | --- | --- | --- |"]
    for engine in IOS_ENGINES:
        cells = [values.get((engine, profile)) for profile in ("steady", "fast", "flicks")]
        if any(c is not None for c in cells):
            lines.append(f"| {engine} | " + " | ".join("—" if c is None else ios_number(c) for c in cells) + " |")
    return lines


def ios_meter_table(files, profile="flicks"):
    """The app's own meter, a test's medians: frames a second · main thread busy · process CPU."""
    reports = [json.loads((RESULTS / "ios" / name).read_text()) for _, name in files]
    lines = ["| Engine | " + " | ".join(label for label, _ in files) + " |", "| --- |" + " --- |" * len(files)]
    for engine in IOS_ENGINES:
        cells = []
        for report in reports:
            summary = next((s for s in report["summary"] if s["engine"] == engine and s["profile"] == profile), None)
            cells.append("—" if summary is None else f"{ios_number(summary['medianFPS'])} · {number(summary['medianMainThreadBusyPercent'])}%"
                         f" · {number(summary['medianProcessCPUPercent'])}% CPU")
        lines.append(f"| {engine} | " + " | ".join(cells) + " |")
    return lines


# MARK: The tables

DEFAULT_HEADERS = ["Live trades: 20,000 rows, ~44,800 changes/s", "Wide live trades: the same, 24 columns",
                   "Order book: 200,000 rows, ~243,500 changes/s", "Trade feed: 1,000,000 rows, ~300,000 changes/s"]

# The sets each table cites (several sets of one measurement are combined).
DEFAULT = ["2026-11-24-0906.jsonl"]
LARGE = ["2026-11-24-1037.jsonl"]
MACBOOK_4K = ["2026-11-25-0100.jsonl"]
MACBOOK_4K_HISTORY = ["2026-11-24-0229.jsonl", "2026-11-24-1124.jsonl", "2026-11-24-1215.jsonl", "2026-11-24-1456.jsonl",
                      "2026-11-25-0100.jsonl"]
DISPLAY_4K_FILL = ["2026-11-24-1258.jsonl"]
DISPLAY_4K = ["2026-11-24-1345.jsonl"]
DISPLAY_4K_CELLS_LIVE = ["2026-11-24-1648.jsonl"]

TABLES = {
    "default": lambda: screen_table(DEFAULT, headers=DEFAULT_HEADERS),
    "default-cost": lambda: cost_table(DEFAULT),
    "large": lambda: updates_table(LARGE),
    "large-cost": lambda: cost_table(LARGE),
    "macbook-4k": lambda: updates_table(MACBOOK_4K),
    "macbook-4k-cost": lambda: cost_table(MACBOOK_4K),
    "macbook-4k-history": lambda: history_table(MACBOOK_4K_HISTORY, "gingham"),
    "display-4k-fill": lambda: updates_table(DISPLAY_4K_FILL),
    "display-4k": lambda: updates_table(DISPLAY_4K, overrides={("nstable-cells", "live-trades"): DISPLAY_4K_CELLS_LIVE}),
    "sorts": lambda: sort_table(DEFAULT),
    "binance": lambda: binance_table(DEFAULT),
    "sources": lambda: sources_table([("Default window, sorts, Binance", DEFAULT), ("2040 × 1080", LARGE),
                                      ("3840 × 2160", MACBOOK_4K), ("3840 × 2160, Gingham's earlier sets", MACBOOK_4K_HISTORY[:-1]),
                                      ("4K display, filled", DISPLAY_4K_FILL),
                                      ("4K display, 3840 × 2160", DISPLAY_4K + DISPLAY_4K_CELLS_LIVE)]),
    "ios-hitches": lambda: ios_hitches_table("2026-11-24-185915"),
    "ios-meter": lambda: ios_meter_table([("100,000 rows, 1,000 changes/s", "ios-100k-2026-11-24-185915.json"),
                                          ("1,000,000 rows, 10,000 changes/s", "ios-1m-2026-11-24-185915.json")]),
}

# Made only where the README has their markers: they wait for the next session's results (put the
# set's file into the list, and the markers into the README).
EQUAL_RATE_30 = []        # Scripts/next-session.sh step 4 (the default window, --update-rate 30)
EQUAL_RATE_30_LARGE = []  # step 5 (2040 × 1080)
EQUAL_RATE_60_LARGE = []  # step 6
QUIET_AND_SCROLL = []     # step 1 (the default set): quiet-table and scroll
QUIET = [("quiet-table", "Quiet table: 5,000 rows, 10 changes/s"), ("scroll", "Scrolling 100,000 rows")]
PENDING = {
    "rate30-default": lambda: updates_table(EQUAL_RATE_30),
    "rate30-default-cost": lambda: cost_table(EQUAL_RATE_30),
    "rate30-large": lambda: updates_table(EQUAL_RATE_30_LARGE),
    "rate30-large-cost": lambda: cost_table(EQUAL_RATE_30_LARGE),
    "rate60-large": lambda: updates_table(EQUAL_RATE_60_LARGE),
    "rate60-large-cost": lambda: cost_table(EQUAL_RATE_60_LARGE),
    "quiet-scroll": lambda: updates_table(QUIET_AND_SCROLL, scenarios=QUIET),
    "quiet-scroll-cost": lambda: cost_table(QUIET_AND_SCROLL, scenarios=QUIET),
}


def main():
    readme = ROOT / "README.md"
    text = readme.read_text()
    pattern = re.compile(r"(<!-- table: (\S+) -->\n)(.*?)(<!-- /table -->)", re.S)
    present = set(m.group(2) for m in pattern.finditer(text))
    missing = set(TABLES) - present
    if missing:
        sys.exit(f"README.md has no table markers for: {', '.join(sorted(missing))}")
    unknown = present - set(TABLES) - set(PENDING)
    if unknown:
        sys.exit(f"README.md has markers of no table: {', '.join(sorted(unknown))}")
    makers = {**PENDING, **TABLES}
    new = pattern.sub(lambda m: m.group(1) + "\n".join(makers[m.group(2)]()) + "\n" + m.group(4), text)
    if "--check" in sys.argv:
        if new != text:
            sys.exit("README.md's tables differ from the results files: run Scripts/readme-tables.py")
        print("README.md's tables are the results files'.")
        return
    readme.write_text(new)
    print("README.md's tables made from the results files.")


if __name__ == "__main__":
    main()
