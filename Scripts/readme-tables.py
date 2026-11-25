#!/usr/bin/env python3
"""The README's Results tables, made from the results files (never typed by hand).

Each table in README.md sits between `<!-- table: NAME -->` and `<!-- /table -->`; this script
replaces what is between them with the table made from the JSON lines it cites, rounded as the
app's own Markdown (Report.swift) rounds: medians of the runs, to the nearest and ties to even.

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


def title(engine, name):
    for run in runs(name):
        if run["engine"] == engine:
            return run["engineTitle"]
    return engine


def of(name, scenario, engine):
    all_runs = [r for r in runs(name) if r["scenario"] == scenario and r["engine"] == engine]
    measured = [r for r in all_runs if not r.get("pass")]
    ok = [r for r in measured if r["status"] == "ok" and r.get("numbers")]
    return all_runs, measured, ok


def failed(measured, ok):
    """'stuck', or a note on the runs that failed (empty: none did)."""
    bad = [r for r in measured if r not in ok]
    if not bad:
        return ""
    statuses = sorted({r["status"] for r in bad})
    if not ok:
        return " / ".join(statuses)
    return f" ({len(ok)} of {len(measured)} runs; {len(bad)} {' / '.join(statuses)})"


def values(name, scenario, engine, kind):
    """The cell's numbers (rounded texts) or a failure text."""
    all_runs, measured, ok = of(name, scenario, engine)
    if not measured:
        return None
    note = failed(measured, ok)
    if not ok:
        return note
    numbers = [r["numbers"] for r in ok]
    busy = number(median([n["busyShare"] * 100 for n in numbers]))
    ages = [n["dataAgeP50Ms"] for n in numbers if n.get("dataAgeP50Ms") is not None]
    age = number(median(ages)) if ages else "—"
    if kind == "screen":
        screens = [r["numbers"]["screenUpdatesPerSecond"] for r in all_runs
                   if r.get("pass") != "trace" and r["status"] == "ok" and r.get("numbers")
                   and r["numbers"].get("screenUpdatesPerSecond") is not None]
        first = number(median(screens)) if screens else "—"
        label = ""
    else:
        presented = [n["presentedPerSecond"] for n in numbers if n.get("presentedPerSecond") is not None]
        if kind == "presented" and presented:
            first, label = number(median(presented)), " presented"
        else:
            first, label = number(median([n["updatesAppliedPerSecond"] for n in numbers])), " applied"
    return (first, label, busy, age, note)


def cell(name, scenario, engine, kind, also=()):
    """One cell; `also`: more files of the same method whose numbers make ranges."""
    parts = [values(n, scenario, engine, kind) for n in (name, *also)]
    first = parts[0]
    if first is None:
        return "—"
    if isinstance(first, str):
        return first
    if also and all(isinstance(p, tuple) for p in parts):
        def span(index):
            texts = sorted({p[index] for p in parts}, key=lambda t: float(t.replace(",", "")))
            return texts[0] if len(texts) == 1 else f"{texts[0]}–{texts[-1]}"
        first = (span(0), first[1], span(2), span(3), first[4])
    value, label, busy, age, note = first
    return f"{value}{label} · {busy}% · {age} ms{note}"


def live_table(name, kind, scenarios=LIVE, ranges=None, overrides=None, headers=None):
    ranges, overrides = ranges or {}, overrides or {}
    header = headers or [label for _, label in scenarios]
    lines = ["| Engine | " + " | ".join(header) + " |", "| --- |" + " --- |" * len(scenarios)]
    for engine in ENGINES:
        cells = []
        for scenario, _ in scenarios:
            source = overrides.get((engine, scenario), name)
            cells.append(cell(source, scenario, engine, kind, ranges.get((engine, scenario), ())))
        if all(c == "—" for c in cells):
            continue
        lines.append(f"| {title(engine, name)} | " + " | ".join(cells) + " |")
    return lines


def sort_cell(name, scenario, engine):
    _, measured, ok = of(name, scenario, engine)
    ok = [r for r in measured if r["status"] == "ok" and r.get("sorts")]
    if not ok:
        bad = [r for r in measured if r["status"] != "ok"]
        if bad and all("didn't reach the screen within 60 s" in (r.get("note") or "") for r in bad):
            return "no sorted order within 60 s"
        return " / ".join(sorted({r["status"] for r in bad})) or "—"
    sorts = [s for r in ok for s in r["sorts"]]

    def step(name):
        return [s for s in sorts if s.get("step") == name]
    first, again = step("first"), step("again")
    seconds = lambda ss: number(median([s["seconds"] for s in ss]), 2) + " s" if ss else "—"
    stall = number(median([s["longestFrameGapMs"] for s in first])) + " ms" if first else "—"
    return f"{seconds(first)} · {seconds(again)} · {stall}"


def has_runs(name, engine):
    return any(r["engine"] == engine for r in runs(name))


def sort_table(name):
    lines = ["| Engine | By pair | By account |", "| --- | --- | --- |"]
    for engine in ENGINES:
        if not has_runs(name, engine):
            continue
        lines.append(f"| {title(engine, name)} | {sort_cell(name, 'sort-text', engine)} | {sort_cell(name, 'sort-text-account', engine)} |")
    return lines


def binance_table(name):
    lines = ["| Engine | Tickers | Order books |", "| --- | --- | --- |"]
    for engine in ENGINES:
        if not has_runs(name, engine):
            continue
        lines.append(f"| {title(engine, name)} | {cell(name, 'binance-tickers', engine, 'screen')} | "
                     f"{cell(name, 'binance-books', engine, 'applied')} |")
    return lines


DEFAULT_HEADERS = ["Live trades: 20,000 rows, ~44,800 changes/s", "Wide live trades: the same, 24 columns",
                   "Order book: 200,000 rows, ~243,500 changes/s", "Trade feed: 1,000,000 rows, ~300,000 changes/s"]

TABLES = {
    "default": lambda: live_table("2026-11-24-0906.jsonl", "screen", headers=DEFAULT_HEADERS),
    "large": lambda: live_table("2026-11-24-1037.jsonl", "presented"),
    "macbook-4k": lambda: live_table("2026-11-25-0100.jsonl", "presented"),
    "display-4k-fill": lambda: live_table("2026-11-24-1258.jsonl", "presented"),
    "display-4k": lambda: live_table("2026-11-24-1345.jsonl", "presented", overrides={
        ("nstable-cells", "live-trades"): "2026-11-24-1648.jsonl"}),
    "sorts": lambda: sort_table("2026-11-24-0906.jsonl"),
    "binance": lambda: binance_table("2026-11-24-0906.jsonl"),
}


def main():
    readme = ROOT / "README.md"
    text = readme.read_text()
    pattern = re.compile(r"(<!-- table: (\S+) -->\n)(.*?)(<!-- /table -->)", re.S)
    missing = set(TABLES) - set(m.group(2) for m in pattern.finditer(text))
    if missing:
        sys.exit(f"README.md has no table markers for: {', '.join(sorted(missing))}")
    new = pattern.sub(lambda m: m.group(1) + "\n".join(TABLES[m.group(2)]()) + "\n" + m.group(4), text)
    if "--check" in sys.argv:
        if new != text:
            sys.exit("README.md's tables differ from the results files: run Scripts/readme-tables.py")
        print("README.md's tables are the results files'.")
        return
    readme.write_text(new)
    print("README.md's tables made from the results files.")


if __name__ == "__main__":
    main()
