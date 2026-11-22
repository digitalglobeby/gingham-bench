//
//  Meter.swift
//  Gingham Bench
//
//  What is measured, the same way for every engine:
//
//  - Frames: callbacks of a CADisplayLink of the window's screen, run on the main thread. It
//    fires once per screen refresh when the main thread is free to take it; a main thread busy
//    for longer misses refreshes. So "frames/s" is how many screen refreshes the main thread got
//    to (the most it can update the table), not a count of frames the window server composited.
//    For Gingham, which can tell, frames presented on the screen are counted too
//    (`GHTableView.framePresented`).
//  - Main thread busy: the share of time its run loop wasn't waiting (a run loop observer of
//    `beforeWaiting`/`afterWaiting`): applying changes, layout, drawing, Core Animation's commit,
//    everything the app and the framework do on it. Less is more room for the app.
//  - Longest frame gap: the longest time between two display-link callbacks, the longest the
//    screen waited for the main thread.
//  - Changes: row changes applied to the store and told to the engine.
//  - Process CPU (all threads, 100% = one core) and memory (physical footprint), sampled every
//    250 ms on another thread: work an engine moves off the main thread shows here.
//
//  Everything is recorded with timestamps and summarized over the measured window afterwards,
//  so a late timer doesn't change a number; a watchdog thread can summarize when the main thread
//  never comes back.
//

import AppKit
import Darwin

/// The recorded timestamps, shared with the watchdog thread.
nonisolated final class MeterData: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [CFTimeInterval] = []
    private var waits: [(start: CFTimeInterval, end: CFTimeInterval)] = []
    private var waitStart: CFTimeInterval?
    private var presented: [CFTimeInterval] = []
    private var changes: [(time: CFTimeInterval, count: Int)] = []
    private var samples: [(time: CFTimeInterval, cpu: Double, footprint: Double)] = []

    func frame(_ time: CFTimeInterval) { lock.withLock { frames.append(time) } }
    func presented(_ time: CFTimeInterval) { lock.withLock { presented.append(time) } }
    func changes(_ count: Int, at time: CFTimeInterval) { lock.withLock { changes.append((time, count)) } }
    func waitBegan(_ time: CFTimeInterval) { lock.withLock { waitStart = time } }
    func waitEnded(_ time: CFTimeInterval) {
        lock.withLock {
            if let start = waitStart { waits.append((start, time)) }
            waitStart = nil
        }
    }
    func sample(_ time: CFTimeInterval, cpu: Double, footprint: Double) { lock.withLock { samples.append((time, cpu, footprint)) } }

    var lastFrame: CFTimeInterval? { lock.withLock { frames.last } }
    func frames(in range: ClosedRange<CFTimeInterval>) -> [CFTimeInterval] { lock.withLock { frames.filter { range.contains($0) } } }

    /// Frames and busy share of the last second (for the window's numbers).
    func lastSecond(now: CFTimeInterval) -> (frames: Int, busy: Double, presented: Int) {
        lock.withLock {
            let from = now - 1
            let frameCount = frames.reversed().prefix { $0 >= from }.count
            let presentedCount = presented.reversed().prefix { $0 >= from }.count
            var waited = 0.0
            for wait in waits.reversed() {
                if wait.end < from { break }
                waited += wait.end - max(wait.start, from)
            }
            if let start = waitStart { waited += now - max(start, from) }
            return (frameCount, min(1, max(0, 1 - waited)), presentedCount)
        }
    }

    /// Drops what's older than a minute (long interactive sessions).
    func trim(before time: CFTimeInterval) {
        lock.withLock {
            frames.removeAll { $0 < time }
            waits.removeAll { $0.end < time }
            presented.removeAll { $0 < time }
            changes.removeAll { $0.time < time }
            samples.removeAll { $0.time < time }
        }
    }

    /// Numbers over a window.
    func summary(from start: CFTimeInterval, to end: CFTimeInterval) -> RunNumbers {
        lock.withLock {
            let duration = max(end - start, 1e-9)
            let inWindow = frames.filter { $0 >= start && $0 < end }
            var gap = 0.0, previous = start
            for time in inWindow {
                gap = max(gap, time - previous)
                previous = time
            }
            gap = max(gap, end - previous)
            func waited(_ from: CFTimeInterval, _ to: CFTimeInterval) -> Double {
                var total = 0.0
                for wait in waits where wait.end > from && wait.start < to { total += min(wait.end, to) - max(wait.start, from) }
                if let begun = waitStart, begun < to { total += to - max(begun, from) }
                return total
            }
            let seconds = Int(duration.rounded(.down))
            var perSecond: [SecondNumbers] = []
            for second in 0..<seconds {
                let from = start + Double(second), to = from + 1
                perSecond.append(SecondNumbers(
                    frames: frames.lazy.filter { $0 >= from && $0 < to }.count,
                    busy: 1 - waited(from, to),
                    changes: changes.lazy.filter { $0.time >= from && $0.time < to }.reduce(0) { $0 + $1.count },
                    presented: presented.lazy.filter { $0 >= from && $0 < to }.count))
            }
            let before = samples.last { $0.time <= start } ?? samples.first
            let after = samples.first { $0.time >= end } ?? samples.last
            var cpu: Double?
            if let before, let after, after.time > before.time { cpu = (after.cpu - before.cpu) / (after.time - before.time) * 100 }
            let footprint = samples.filter { $0.time >= start && $0.time <= end }.map(\.footprint).max() ?? samples.last?.footprint
            return RunNumbers(
                seconds: duration,
                framesPerSecond: Double(inWindow.count) / duration,
                worstSecondFrames: perSecond.map(\.frames).min(),
                busyShare: min(1, max(0, 1 - waited(start, end) / duration)),
                longestFrameGapMs: gap * 1000,
                changesPerSecond: Double(changes.filter { $0.time >= start && $0.time < end }.reduce(0) { $0 + $1.count }) / duration,
                presentedPerSecond: presented.isEmpty ? nil : Double(presented.filter { $0 >= start && $0 < end }.count) / duration,
                cpuPercent: cpu,
                memoryMB: footprint,
                perSecond: perSecond)
        }
    }
}

nonisolated struct SecondNumbers: Codable, Sendable {
    var frames: Int
    var busy: Double
    var changes: Int
    var presented: Int
}

nonisolated struct RunNumbers: Codable, Sendable {
    var seconds: Double
    var framesPerSecond: Double
    var worstSecondFrames: Int?
    var busyShare: Double
    var longestFrameGapMs: Double
    var changesPerSecond: Double
    var presentedPerSecond: Double?
    var cpuPercent: Double?
    var memoryMB: Double?
    var perSecond: [SecondNumbers]
}

/// The display link and the run loop observer, recording into `MeterData`.
final class Meter: NSObject {
    let data = MeterData()
    private var link: CADisplayLink?
    private var observer: CFRunLoopObserver?
    private var sampler: Thread?
    /// Called on each display-link callback, after it's recorded.
    var onFrame: ((CFTimeInterval) -> Void)?
    private(set) var refreshRate = 0

    func start(on view: NSView) {
        guard link == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        let rate = Float(view.window?.screen?.maximumFramesPerSecond ?? 60)
        refreshRate = Int(rate)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
        let data = data
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue,
                                                      true, Int.max) { _, activity in
            let now = CACurrentMediaTime()
            if activity == .beforeWaiting { data.waitBegan(now) } else { data.waitEnded(now) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        let sampler = Thread {
            while !Thread.current.isCancelled {
                data.sample(CACurrentMediaTime(), cpu: Self.processCPUSeconds(), footprint: Self.footprintMB())
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        sampler.name = "Meter sampler"
        sampler.qualityOfService = .utility
        sampler.start()
        self.sampler = sampler
    }

    func stop() {
        link?.invalidate()
        link = nil
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        sampler?.cancel()
        sampler = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        data.frame(now)
        onFrame?(now)
    }

    func presented() { data.presented(CACurrentMediaTime()) }

    nonisolated static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    nonisolated static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
