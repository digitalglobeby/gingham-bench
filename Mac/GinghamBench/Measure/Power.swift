//
//  Power.swift
//  Gingham Bench
//
//  The Mac's power during each run, from a `powermetrics` recording. powermetrics needs root,
//  which the bench never asks for: the Mac's owner records the whole session in a terminal of
//  their own,
//
//    sudo powermetrics -s cpu_power,gpu_power,tasks --show-process-gpu --show-process-energy \
//        -i 1000 -f plist -o ~/gingham-power.plist
//
//  and `--power FILE` (with the measurement, or later with `--summarize`) attaches to every run of
//  the results file the medians of the samples taken inside its measured window
//  (`windowStartEpoch`…`windowEndEpoch`):
//
//  - the power of the CPU, of the GPU and both together, mW (powermetrics' `processor` block: the
//    whole Mac's CPU and GPU, every process, the window server's compositing included; not the
//    display, memory or the rest of the board), and the energy an update (both together over the
//    updates applied a second);
//  - the GPU's clock (MHz, in the samples it was active in) and the share of time it was active:
//    "GPU ms/s" is time at whatever clock the GPU ran (on a quiet screen it may stay at its
//    lowest), so power, not GPU time, is the cost to compare;
//  - from `tasks`, the window server's CPU (otherwise not measured: another user's process) and
//    the run's own process's, percent of a core.
//
//  A sample covers the interval before its `timestamp`, which is given to the second: only the
//  samples wholly inside the window count (taken at least the sample's length and half a second
//  after its start, and at least a second before its end), about 7 of a 10-second window. The
//  file is the samples one after another, each a property list followed by a NUL byte; only the
//  samples near a run's window are parsed (with `tasks` a session's file grows by ~160 KB a second).
//

import Foundation

/// A run's power, from `powermetrics` (`--power`).
nonisolated struct PowerNumbers: Codable, Sendable {
    /// The samples inside the measured window.
    var samples: Int
    /// Medians of the samples, mW: the CPU's, the GPU's, and powermetrics' combined power (CPU, GPU
    /// and the neural engine, which nothing here uses).
    var cpuMilliwatts: Double
    var gpuMilliwatts: Double
    var combinedMilliwatts: Double
    /// The combined power over the updates applied a second: the energy an update, mJ.
    var millijoulesPerUpdate: Double?
    /// The GPU's clock in the samples it was active in, MHz, and the median share of time it was
    /// active.
    var gpuMHz: Double?
    var gpuActiveShare: Double
    /// From the samples' tasks, percent of a core: the window server's CPU, and the run's process's.
    var windowServerCPUPercent: Double?
    var processCPUPercent: Double?
    /// The recording's file name.
    var file: String
}

nonisolated enum PowerMetrics {
    struct Sample {
        /// The end of the sample's interval (seconds since 1970, to the second) and its length.
        var time: Double
        var seconds: Double
        var cpu: Double
        var gpu: Double
        var combined: Double
        var gpuMHz: Double
        var gpuActive: Double
        var windowServerCPU: Double?
        var cpuByProcess: [Int: Double]
    }

    /// Attaches power to every run of a results file that has a measured window inside the
    /// recording (rewriting the file); what it did, in a line.
    static func attach(recording path: String, to results: String) -> String {
        guard let text = try? String(contentsOfFile: results, encoding: .utf8) else { return "no results file \(results)" }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let runs = lines.map { try? decoder.decode(RunResult.self, from: Data($0.utf8)) }
        let windows = runs.compactMap { run -> ClosedRange<Double>? in
            guard let run, run.numbers != nil, let start = run.windowStartEpoch, let end = run.windowEndEpoch, end > start else { return nil }
            return start...end
        }
        guard !windows.isEmpty else { return "no measured windows in \(results)" }
        let read = samples(in: path, near: windows)
        guard let first = read.first, let last = read.last else {
            return "no powermetrics samples in \(path)" + (read.error.map { " (\($0))" } ?? "")
        }
        let file = (path as NSString).lastPathComponent
        var attached = 0, outside = 0
        for (index, run) in runs.enumerated() {
            guard var run, let numbers = run.numbers, let start = run.windowStartEpoch, let end = run.windowEndEpoch else { continue }
            let inside = read.samples.filter { $0.time >= start + $0.seconds + 0.5 && $0.time <= end - 1 }
            guard !inside.isEmpty else {
                outside += 1
                continue
            }
            let combined = median(inside.map(\.combined))
            let active = inside.filter { $0.gpuMHz > 0 }
            run.power = PowerNumbers(
                samples: inside.count, cpuMilliwatts: median(inside.map(\.cpu)), gpuMilliwatts: median(inside.map(\.gpu)),
                combinedMilliwatts: combined,
                millijoulesPerUpdate: numbers.updatesAppliedPerSecond > 0 ? combined / numbers.updatesAppliedPerSecond : nil,
                gpuMHz: active.isEmpty ? nil : median(active.map(\.gpuMHz)), gpuActiveShare: median(inside.map(\.gpuActive)),
                windowServerCPUPercent: optionalMedian(inside.compactMap(\.windowServerCPU)),
                processCPUPercent: run.pid.flatMap { pid in optionalMedian(inside.compactMap { $0.cpuByProcess[Int(pid)] }) },
                file: file)
            lines[index] = run.jsonLine
            attached += 1
        }
        if attached > 0 { try? (lines.joined(separator: "\n") + "\n").write(toFile: results, atomically: true, encoding: .utf8) }
        let range = "\(Date(timeIntervalSince1970: first).formatted(date: .omitted, time: .standard))–\(Date(timeIntervalSince1970: last).formatted(date: .omitted, time: .standard))"
        return "Mac power attached to \(attached) of \(windows.count) measured runs (samples \(range))"
            + (outside > 0 ? "; \(outside) runs had no samples inside their window (was powermetrics recording then?)" : "")
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    private static func optionalMedian(_ values: [Double]) -> Double? { values.isEmpty ? nil : median(values) }

    /// The samples within a few seconds of the windows (only those are parsed), in order, and the
    /// times of the recording's first and last samples.
    static func samples(in path: String, near windows: [ClosedRange<Double>]) -> (samples: [Sample], first: Double?, last: Double?, error: String?) {
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) } catch {
            return ([], nil, nil, error.localizedDescription)
        }
        let wanted = windows.map { ($0.lowerBound - 3)...($0.upperBound + 3) }.sorted { $0.lowerBound < $1.lowerBound }
        var samples: [Sample] = []
        var first: Double?, last: Double?
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = buffer.count
            var start = 0
            while start < count {
                let end = memchr(base + start, 0, count - start).map { UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self) - base } ?? count
                var from = start
                while from < end, base[from] == 0x0A || base[from] == 0x0D || base[from] == 0x20 || base[from] == 0x09 { from += 1 }
                defer { start = end + 1 }
                guard end - from > 64, let time = timestamp(base + from, count: end - from) else { continue }
                if first == nil { first = time }
                last = time
                guard wanted.contains(where: { $0.contains(time) }),
                      let sample = parse(Data(bytes: base + from, count: end - from), time: time) else { continue }
                samples.append(sample)
            }
        }
        return (samples, first, last, nil)
    }

    /// A sample's `timestamp` (an XML plist date, "2026-11-25T16:26:52Z"), found near its start.
    private static func timestamp(_ bytes: UnsafePointer<UInt8>, count: Int) -> Double? {
        let key = Array("<key>timestamp</key><date>".utf8)
        let window = min(count, 8192)
        guard let found = key.withUnsafeBufferPointer({ memmem(bytes, window, $0.baseAddress, key.count) }) else { return nil }
        let at = UnsafeRawPointer(found).assumingMemoryBound(to: UInt8.self) + key.count
        guard at + 20 <= bytes + count else { return nil }
        func number(_ offset: Int, _ length: Int) -> Int32? {
            var value: Int32 = 0
            for index in offset ..< offset + length {
                let digit = Int32(at[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard at[19] == UInt8(ascii: "Z"), let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2) else { return nil }
        var parts = tm()
        parts.tm_year = year - 1900
        parts.tm_mon = month - 1
        parts.tm_mday = day
        parts.tm_hour = hour
        parts.tm_min = minute
        parts.tm_sec = second
        return Double(timegm(&parts))
    }

    private static func parse(_ data: Data, time: Double) -> Sample? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let processor = plist["processor"] as? [String: Any] else { return nil }
        func double(_ dictionary: [String: Any]?, _ key: String) -> Double? { (dictionary?[key] as? NSNumber)?.doubleValue }
        let gpu = plist["gpu"] as? [String: Any]
        var windowServer: Double?
        var byProcess: [Int: Double] = [:]
        for task in plist["tasks"] as? [[String: Any]] ?? [] {
            guard let pid = (task["pid"] as? NSNumber)?.intValue, let cpu = double(task, "cputime_ms_per_s") else { continue }
            byProcess[pid] = cpu / 10
            if task["name"] as? String == "WindowServer" { windowServer = (windowServer ?? 0) + cpu / 10 }
        }
        let cpu = double(processor, "cpu_power") ?? 0, gpuPower = double(processor, "gpu_power") ?? 0
        return Sample(time: time, seconds: (double(plist, "elapsed_ns") ?? 1e9) / 1e9, cpu: cpu, gpu: gpuPower,
                      combined: double(processor, "combined_power") ?? cpu + gpuPower,
                      gpuMHz: double(gpu, "freq_hz") ?? 0, gpuActive: 1 - (double(gpu, "idle_ratio") ?? 1),
                      windowServerCPU: windowServer, cpuByProcess: byProcess)
    }
}
