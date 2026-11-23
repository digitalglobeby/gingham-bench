#!/usr/bin/env python3 -I
"""Summarizes an Instruments "Animation Hitches" trace of Gingham Bench.

    python3 -I iOS/Scripts/hitches-summary.py <trace> > summary.json

Exports the trace's tables with `xctrace export` and reports, from the render
server's hitches (not the app's own meter): the hitches in each of the app's
measured tests (its "Scroll test" signpost intervals, recorded with the
os_signpost instrument), their count, total time and hitch time ratio (ms of
hitches per second), and the same over the whole recording. It lists the
tables it found, so a change in Instruments' table names shows up instead of
silently giving zeros. Run-device.sh calls it after each recording.
"""

import json
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


def export(trace, *arguments):
    with tempfile.NamedTemporaryFile(suffix=".xml") as output:
        subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--output", output.name, *arguments],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return ET.parse(output.name).getroot()


def table_schemas(toc):
    return sorted({table.get("schema") for table in toc.iter("table") if table.get("schema")})


def rows(trace, schema):
    """The table's rows as dicts of column mnemonic -> (value, formatted)."""
    root = export(trace, "--xpath", f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]')
    columns = [col.findtext("mnemonic") for col in root.iter("col")]
    # A value given once (with an id, possibly nested in another value) is
    # referred to later by `ref`.
    defined = {element.get("id"): element for element in root.iter() if element.get("id") is not None}
    result = []
    for row in root.iter("row"):
        values = {}
        for column, element in zip(columns, list(row)):
            if element.get("ref") is not None:
                element = defined.get(element.get("ref"), element)
            text = (element.text or "").strip()
            values[column] = (text, element.get("fmt") or text)
        result.append(values)
    return result


def warn(message):
    print(f"hitches-summary: warning: {message}", file=sys.stderr)


def number(value):
    try:
        return int(value[0])
    except (TypeError, ValueError, IndexError):
        return None


def main():
    trace = sys.argv[1]
    toc = export(trace, "--toc")
    schemas = table_schemas(toc)
    summary = {"trace": str(Path(trace).name), "tables": schemas}

    hitch_schema = "hitches" if "hitches" in schemas else next((s for s in schemas if s.startswith("hitches")), None)
    if hitch_schema and hitch_schema != "hitches":
        warn(f"no 'hitches' table; using '{hitch_schema}' instead: check it lists hitches (tables: {', '.join(schemas)})")
    elif not hitch_schema:
        warn(f"no hitches table in {trace} (tables: {', '.join(schemas)})")
    hitches = []
    if hitch_schema:
        for row in rows(trace, hitch_schema):
            start, duration = number(row.get("start")), number(row.get("duration"))
            if start is None or duration is None:
                continue
            process = (row.get("process") or ("", ""))[1]
            hitches.append({"start": start, "duration": duration, "process": process})
        # Only the bench's own hitches when the table says whose they are.
        ours = [h for h in hitches if "Gingham Bench" in h["process"] or "GinghamBench" in h["process"]]
        if ours:
            hitches = ours
        elif hitches:
            warn("the hitches name no process of Gingham Bench: counting every process's hitches")
            summary["warning"] = "hitches not filtered by process"

    summary["hitchTable"] = hitch_schema

    tests = []
    signpost_schema = next((s for s in ("OSSignpostIntervals", "os-signpost-interval") if s in schemas), None) \
        or next((s for s in schemas if "signpost" in s.lower() and "interval" in s.lower()), None)
    if signpost_schema:
        listed = set()
        for row in rows(trace, signpost_schema):
            name = (row.get("name") or ("", ""))[1]
            if name != "Scroll test":
                continue
            start, duration = number(row.get("start")), number(row.get("duration"))
            if start is None or not duration:
                continue
            label = next((row[key][1] for key in ("message", "start-message", "start-message-string") if key in row), "")
            # (The table can list an interval more than once.)
            if (start, duration, label) in listed:
                continue
            listed.add((start, duration, label))
            inside = [h for h in hitches if start <= h["start"] < start + duration]
            total = sum(h["duration"] for h in inside)
            tests.append({"test": label, "seconds": round(duration / 1e9, 3), "hitches": len(inside),
                          "hitchTimeMs": round(total / 1e6, 1),
                          "hitchTimeMsPerSecond": round(total / 1e6 / (duration / 1e9), 1)})
    summary["signpostTable"] = signpost_schema
    summary["tests"] = tests
    summary["allHitches"] = {"count": len(hitches), "hitchTimeMs": round(sum(h["duration"] for h in hitches) / 1e6, 1)}
    if not hitch_schema:
        summary["note"] = "No hitches table in the trace (Animation Hitches needs a device); see 'tables'."
    json.dump(summary, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
