//
//  TraceFrames.swift
//  Gingham Bench
//
//  The system's own count of the bench window's frames, from an Instruments trace of the run
//  (`--trace-pass`: `xctrace record --instrument Hitches --instrument Display --attach <pid>` of a
//  measuring run). Two of the tables they record are per process:
//
//  - `hitches-updates` ("Client Updates"): each Core Animation commit of a process that went into
//    a frame the window server put on the display (with the display swap it went into). AppKit
//    and SwiftUI tables change the screen only through such commits; so do the window's top bar
//    and header. A commit isn't necessarily a visible change (a commit may change nothing seen).
//  - `metal-io-surface-access`: each GPU access to an IOSurface, by process, the window server's
//    reads included. Gingham's table is drawn by the GPU, and its frames show up here; a frame
//    counts as shown when the window server read the surface after the process's GPU wrote it and
//    before the next write. (These frames reach the screen without a commit, so they aren't client
//    updates.)
//
//  `framesShownPerSecond` is the two together: the window's frames the system says it showed.
//  The display's own frames (`displayed-surfaces-interval`) are the whole display's, not a
//  window's, so they aren't used.
//

import Foundation

nonisolated enum TraceFrames {
    /// A table of an `xctrace export`: its columns (mnemonics) and rows (each column's text and
    /// display string, references resolved).
    struct Table {
        var columns: [String] = []
        var rows: [[(text: String, display: String)]] = []

        func column(_ name: String) -> Int? { columns.firstIndex(of: name) }
    }

    private final class TableParser: NSObject, XMLParserDelegate {
        var table = Table()
        private var values: [String: (text: String, display: String)] = [:]
        private var depthInRow = 0
        private var inSchema = false
        private var inMnemonic = false
        private var current: [(text: String, display: String)] = []
        /// The open elements inside a row: id, fmt, text so far, whether a reference.
        private var stack: [(id: String?, fmt: String?, text: String, isRef: Bool)] = []

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            if element == "schema" { inSchema = true }
            if inSchema, element == "mnemonic" {
                inMnemonic = true
                table.columns.append("")
            }
            if element == "row" {
                depthInRow = 1
                current = []
                return
            }
            guard depthInRow > 0 else { return }
            depthInRow += 1
            if let ref = attributes["ref"] {
                if depthInRow == 2 { current.append(values[ref] ?? ("", "")) }
                stack.append((nil, nil, "", true))
                return
            }
            stack.append((attributes["id"], attributes["fmt"], "", false))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inMnemonic, !table.columns.isEmpty { table.columns[table.columns.count - 1] += string }
            if !stack.isEmpty { stack[stack.count - 1].text += string }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            if element == "schema" { inSchema = false }
            if element == "mnemonic" { inMnemonic = false }
            if element == "row" {
                depthInRow = 0
                table.rows.append(current)
                return
            }
            guard depthInRow > 1, let top = stack.popLast() else { return }
            let value = (text: top.text, display: top.fmt ?? top.text)
            if let id = top.id { values[id] = value }
            if depthInRow == 2, !top.isRef { current.append(value) }
            depthInRow -= 1
        }
    }

    private static func xctrace(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctrace"] + arguments
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("gingham-bench-export-\(UUID().uuidString).xml")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        guard let handle = try? FileHandle(forWritingTo: output) else { return nil }
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        try? handle.close()
        return try? Data(contentsOf: output)
    }

    static func table(_ schema: String, in trace: String) -> Table? {
        guard let data = xctrace(["export", "--input", trace, "--xpath", "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"\(schema)\"]"]) else { return nil }
        let parser = XMLParser(data: data)
        let delegate = TableParser()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.table
    }

    /// When the trace started (seconds since 1970) and how long it is.
    static func span(of trace: String) -> (start: Double, duration: Double)? {
        guard let data = xctrace(["export", "--input", trace, "--toc"]), let text = String(data: data, encoding: .utf8) else { return nil }
        func value(_ tag: String) -> String? {
            guard let open = text.range(of: "<\(tag)>"), let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else { return nil }
            return String(text[open.upperBound..<close.lowerBound])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let start = value("start-date").flatMap(formatter.date(from:)), let duration = value("duration").flatMap(Double.init) else { return nil }
        return (start.timeIntervalSince1970, duration)
    }

    /// The process id in a display string like "Gingham Bench (10004)".
    private static func pid(in display: String) -> Int32? {
        guard let open = display.lastIndex(of: "("), let close = display.lastIndex(of: ")"), open < close else { return nil }
        return Int32(display[display.index(after: open)..<close])
    }

    /// The bench window's frames between two wall-clock times of the run.
    static func measure(trace: String, pid: Int32, from start: Double, to end: Double) -> SystemFrames? {
        guard let span = span(of: trace), end > start else { return nil }
        let traceStart = span.start
        // The part of the window the trace covers (it may start a little after the window did).
        let (coveredStart, coveredEnd) = (max(start, traceStart), min(end, traceStart + span.duration))
        guard coveredEnd > coveredStart else { return nil }
        let (from, to) = ((coveredStart - traceStart) * 1e9, (coveredEnd - traceStart) * 1e9)
        let seconds = coveredEnd - coveredStart
        var frames = SystemFrames(trace: (trace as NSString).lastPathComponent)
        frames.windowCovered = seconds / (end - start)

        // The display's frames (swaps), in time order: a window's new content is shown in one.
        var swaps: [(time: Double, id: String)] = []
        if let table = table("display-surface-swap", in: trace), let time = table.column("timestamp"), let id = table.column("swap-id") {
            for row in table.rows where row.count > max(time, id) {
                if let at = Double(row[time].text) { swaps.append((at, row[id].text)) }
            }
            swaps.sort { $0.time < $1.time }
        }
        var shownSwaps = Set<String>()
        var commits = 0
        if let updates = table("hitches-updates", in: trace), let startColumn = updates.column("start"), let process = updates.column("process") {
            let swapColumn = updates.column("swap-id")
            for row in updates.rows where row.count > max(startColumn, process) {
                guard self.pid(in: row[process].display) == pid, let time = Double(row[startColumn].text), time >= from, time < to else { continue }
                commits += 1
                if let swapColumn, swapColumn < row.count { shownSwaps.insert(row[swapColumn].text) }
            }
            frames.clientUpdatesPerSecond = Double(commits) / seconds
        }

        if let accesses = table("metal-io-surface-access", in: trace), let time = accesses.column("timestamp"), let surface = accesses.column("surface-id"),
           let width = accesses.column("width"), let height = accesses.column("height"), let access = accesses.column("access-type"),
           let processColumn = accesses.column("pid") ?? accesses.column("process") {
            struct Access { var time: Double; var surface: String; var area: Double; var write: Bool; var own: Bool }
            var all: [Access] = []
            for row in accesses.rows where row.count > max(time, surface, width, height, access, processColumn) {
                let owner = Int32(row[processColumn].text) ?? self.pid(in: row[processColumn].display)
                all.append(Access(time: Double(row[time].text) ?? 0, surface: row[surface].text,
                                  area: (Double(row[width].text) ?? 0) * (Double(row[height].text) ?? 0),
                                  write: row[access].text != "0", own: owner == pid))
            }
            // The process's largest drawn surfaces: its table (smaller ones: the header).
            let ownWrites = all.filter { $0.own && $0.write }
            if let largest = ownWrites.map(\.area).max() {
                let tableSurfaces = Set(ownWrites.filter { $0.area == largest }.map(\.surface))
                let events = all.filter { tableSurfaces.contains($0.surface) }.sorted { $0.time < $1.time }
                var drawn = 0, shown = 0
                var pendingDraw: [String: Double] = [:]
                for event in events {
                    if event.own, event.write {
                        if event.time >= from, event.time < to { drawn += 1 }
                        pendingDraw[event.surface] = event.time
                    } else if !event.own, !event.write, let drawnAt = pendingDraw[event.surface] {
                        // The window server read the new frame: it was composited, shown.
                        pendingDraw[event.surface] = nil
                        if drawnAt >= from, drawnAt < to {
                            shown += 1
                            // The display frame it went into: the first swap after the read.
                            var low = 0, high = swaps.count
                            while low < high {
                                let middle = (low + high) / 2
                                if swaps[middle].time < event.time { low = middle + 1 } else { high = middle }
                            }
                            if low < swaps.count { shownSwaps.insert("gpu:" + swaps[low].id) }
                        }
                    }
                }
                frames.gpuFramesPerSecond = Double(drawn) / seconds
                frames.gpuFramesShownPerSecond = Double(shown) / seconds
            }
        }
        // The display frames that showed new content of the window: those its commits went into
        // and those its GPU frames went into, once each.
        var distinct = Set<String>()
        for swap in shownSwaps { distinct.insert(swap.hasPrefix("gpu:") ? String(swap.dropFirst(4)) : swap) }
        frames.framesShownPerSecond = swaps.isEmpty ? frames.clientUpdatesPerSecond : Double(distinct.count) / seconds
        return frames
    }
}
