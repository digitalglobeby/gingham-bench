//
//  Meter.swift
//  Gingham Bench
//
//  What is measured, the same way for every engine. The feed's changes accumulate off the main
//  thread continuously, and at every display-link callback (once per screen refresh, on the main
//  thread) everything pending is applied and the engine told; so an engine that keeps up can
//  show new data at every refresh, and one that doesn't shows it less often and older:
//
//  - Updates shown a second: display-link callbacks that applied changes, the times a second the
//    table got new data to show (at most the screen's refresh rate).
//  - Data age: from a change's generation (or its arrival from the network) to the callback that
//    applied it, median and 99th percentile over the changes.
//  - Main thread busy: the share of time its run loop wasn't waiting (run loop observers of
//    `afterWaiting`, first of all, and `beforeWaiting`, last of all): applying changes, layout,
//    drawing, Core Animation's commit, everything the app and the framework do on it.
//  - Longest stall: the longest time between two display-link callbacks, the longest the screen
//    waited for the main thread.
//  - Callbacks a second ("responsiveness"): display-link callbacks the main thread got to,
//    whether or not they had changes to apply.
//  - Changes applied a second: row changes applied to the store and told to the engine.
//  - Process CPU (all threads, 100% = one core), the process's GPU time (the GPU driver's
//    `accumulatedGPUTime` of the process's GPU clients, what Activity Monitor's GPU column
//    shows) and the window server's GPU time (it composites every app's layers, ours included),
//    the energy the kernel accounts to the process (`task_energy` of `TASK_POWER_INFO_V2`),
//    memory (physical footprint) and the thermal state, sampled every 250 ms on another thread:
//    work an engine moves off the main thread, or to the GPU, shows here. The window server's
//    CPU time isn't measured (another user's process).
//
//  Everything is recorded with timestamps and summarized over the measured window afterwards,
//  so a late timer doesn't change a number; a watchdog thread can summarize when the main thread
//  never comes back.
//

import AppKit
import Darwin
import IOKit

/// A sample of the process on the sampler thread.
nonisolated struct ProcessSample: Sendable {
    var time: CFTimeInterval
    var cpu: Double
    var footprint: Double
    /// GPU time of the process and of the window server, ns; energy accounted to the process, nJ.
    var gpu: Double
    var serverGPU: Double
    var energy: Double
    var thermal: Int
}

/// The recorded timestamps, shared with the watchdog thread.
nonisolated final class MeterData: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [CFTimeInterval] = []
    private var waits: [(start: CFTimeInterval, end: CFTimeInterval)] = []
    private var waitStart: CFTimeInterval?
    private var presented: [CFTimeInterval] = []
    private var changes: [(time: CFTimeInterval, count: Int)] = []
    private var ages: [(time: CFTimeInterval, age: Double, changes: Int)] = []
    private var samples: [ProcessSample] = []
    private var interruptions: [(time: CFTimeInterval, what: String)] = []

    func frame(_ time: CFTimeInterval) { lock.withLock { frames.append(time) } }
    func presented(_ time: CFTimeInterval) { lock.withLock { presented.append(time) } }
    func applied(_ applied: Applied, at time: CFTimeInterval) {
        lock.withLock {
            changes.append((time, applied.changes))
            for (age, count) in applied.ages where count > 0 { ages.append((time, age, count)) }
        }
    }
    func waitBegan(_ time: CFTimeInterval) { lock.withLock { waitStart = time } }
    func waitEnded(_ time: CFTimeInterval) {
        lock.withLock {
            if let start = waitStart { waits.append((start, time)) }
            waitStart = nil
        }
    }
    func sample(_ sample: ProcessSample) { lock.withLock { samples.append(sample) } }
    /// The window was covered, the screen locked or the like: the run doesn't count.
    func interrupted(_ what: String, at time: CFTimeInterval) { lock.withLock { interruptions.append((time, what)) } }

    var lastFrame: CFTimeInterval? { lock.withLock { frames.last } }
    func frames(in range: ClosedRange<CFTimeInterval>) -> [CFTimeInterval] { lock.withLock { frames.filter { range.contains($0) } } }
    func interruptions(in range: ClosedRange<CFTimeInterval>) -> [String] {
        lock.withLock { interruptions.filter { range.contains($0.time) }.map(\.what) }
    }

    /// The last second's numbers (for the window).
    func lastSecond(now: CFTimeInterval) -> (updates: Int, busy: Double, callbacks: Int, age: Double?) {
        lock.withLock {
            let from = now - 1
            let callbacks = frames.reversed().prefix { $0 >= from }.count
            let updates = changes.reversed().prefix { $0.time >= from }.filter { $0.count > 0 }.count
            var waited = 0.0
            for wait in waits.reversed() {
                if wait.end < from { break }
                waited += wait.end - max(wait.start, from)
            }
            if let start = waitStart { waited += now - max(start, from) }
            let recent = Array(ages.reversed().prefix { $0.time >= from })
            return (updates, min(1, max(0, 1 - waited)), callbacks, Self.percentile(recent, 0.5))
        }
    }

    /// The age below which `fraction` of the changes were (weighted by their changes).
    private static func percentile(_ ages: [(time: CFTimeInterval, age: Double, changes: Int)], _ fraction: Double) -> Double? {
        let total = ages.reduce(0) { $0 + $1.changes }
        guard total > 0 else { return nil }
        let sorted = ages.sorted { $0.age < $1.age }
        let target = Double(total) * fraction
        var seen = 0
        for entry in sorted {
            seen += entry.changes
            if Double(seen) >= target { return entry.age }
        }
        return sorted.last?.age
    }

    /// Drops what's older than a minute (long sessions in the window).
    func trim(before time: CFTimeInterval) {
        lock.withLock {
            frames.removeAll { $0 < time }
            waits.removeAll { $0.end < time }
            presented.removeAll { $0 < time }
            changes.removeAll { $0.time < time }
            ages.removeAll { $0.time < time }
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
            let applied = changes.filter { $0.time >= start && $0.time < end }
            let seconds = Int(duration.rounded(.down))
            var perSecond: [SecondNumbers] = []
            for second in 0..<seconds {
                let from = start + Double(second), to = from + 1
                let ofSecond = applied.filter { $0.time >= from && $0.time < to }
                perSecond.append(SecondNumbers(
                    callbacks: inWindow.lazy.filter { $0 >= from && $0 < to }.count,
                    updates: ofSecond.lazy.filter { $0.count > 0 }.count,
                    busy: 1 - waited(from, to),
                    changes: ofSecond.reduce(0) { $0 + $1.count }))
            }
            let agesInWindow = ages.filter { $0.time >= start && $0.time < end }
            let before = samples.last { $0.time <= start } ?? samples.first
            let after = samples.first { $0.time >= end } ?? samples.last
            var cpu: Double?, gpu: Double?, serverGPU: Double?, energy: Double?
            if let before, let after, after.time > before.time {
                let elapsed = after.time - before.time
                cpu = (after.cpu - before.cpu) / elapsed * 100
                gpu = (after.gpu - before.gpu) / elapsed / 1_000_000
                serverGPU = (after.serverGPU - before.serverGPU) / elapsed / 1_000_000
                energy = (after.energy - before.energy) / elapsed / 1_000_000
            }
            let windowSamples = samples.filter { $0.time >= start && $0.time <= end }
            let footprint = windowSamples.map(\.footprint).max() ?? samples.last?.footprint
            let thermal = windowSamples.map(\.thermal).max() ?? samples.last?.thermal
            return RunNumbers(
                seconds: duration,
                updatesShownPerSecond: Double(applied.filter { $0.count > 0 }.count) / duration,
                worstSecondUpdates: perSecond.map(\.updates).min(),
                dataAgeP50Ms: Self.percentile(agesInWindow, 0.5).map { $0 * 1000 },
                dataAgeP99Ms: Self.percentile(agesInWindow, 0.99).map { $0 * 1000 },
                busyShare: min(1, max(0, 1 - waited(start, end) / duration)),
                longestStallMs: gap * 1000,
                callbacksPerSecond: Double(inWindow.count) / duration,
                changesPerSecond: Double(applied.reduce(0) { $0 + $1.count }) / duration,
                presentedPerSecond: presented.isEmpty ? nil : Double(presented.filter { $0 >= start && $0 < end }.count) / duration,
                cpuPercent: cpu,
                gpuMsPerSecond: gpu,
                windowServerGPUMsPerSecond: serverGPU,
                energyMilliwatts: energy,
                memoryMB: footprint,
                thermalState: thermal.map(Machine.thermalName),
                perSecond: perSecond)
        }
    }
}

nonisolated struct SecondNumbers: Codable, Sendable {
    var callbacks: Int
    var updates: Int
    var busy: Double
    var changes: Int
}

nonisolated struct RunNumbers: Codable, Sendable {
    var seconds: Double
    /// Display-link callbacks that applied changes, a second.
    var updatesShownPerSecond: Double
    var worstSecondUpdates: Int?
    /// From generation (or arrival) to the callback that applied it, ms.
    var dataAgeP50Ms: Double?
    var dataAgeP99Ms: Double?
    var busyShare: Double
    /// The longest time between two display-link callbacks, ms.
    var longestStallMs: Double
    /// Display-link callbacks the main thread got to, a second.
    var callbacksPerSecond: Double
    var changesPerSecond: Double
    /// Frames on the screen, for engines that can tell (Gingham); null for the others.
    var presentedPerSecond: Double?
    var cpuPercent: Double?
    /// GPU time of the process, ms a second.
    var gpuMsPerSecond: Double?
    /// GPU time of the window server, ms a second (all apps' compositing; the bench's window is
    /// most of it on a quiet Mac).
    var windowServerGPUMsPerSecond: Double?
    /// Energy the kernel accounts to the process (mostly the CPU's), mW.
    var energyMilliwatts: Double?
    var memoryMB: Double?
    /// The worst thermal state sampled during the window.
    var thermalState: String?
    var perSecond: [SecondNumbers]
}

/// The display link and the run loop observers, recording into `MeterData`.
final class Meter: NSObject {
    let data = MeterData()
    private var link: CADisplayLink?
    private var observers: [CFRunLoopObserver] = []
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
        // The wait ends before any other observer runs after it, and begins after every other
        // observer ran before it (Core Animation's commit included).
        let woke = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { _, _ in
            data.waitEnded(CACurrentMediaTime())
        }
        let sleeps = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { _, _ in
            data.waitBegan(CACurrentMediaTime())
        }
        for observer in [woke, sleeps].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
        let sampler = Thread {
            while !Thread.current.isCancelled {
                data.sample(Self.sample())
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
        for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observers = []
        sampler?.cancel()
        sampler = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        data.frame(now)
        onFrame?(now)
    }

    func presented() { data.presented(CACurrentMediaTime()) }

    nonisolated static func sample() -> ProcessSample {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        var power = task_power_info_v2_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_v2_data_t>.size / MemoryLayout<natural_t>.size)
        let powerResult = withUnsafeMutablePointer(to: &power) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &count) }
        }
        let ok = powerResult == KERN_SUCCESS
        let gpu = gpuTimes()
        return ProcessSample(time: CACurrentMediaTime(), cpu: seconds(usage.ru_utime) + seconds(usage.ru_stime), footprint: footprintMB(),
                             gpu: gpu.own, serverGPU: gpu.windowServer, energy: ok ? Double(power.task_energy) : 0,
                             thermal: ProcessInfo.processInfo.thermalState.rawValue)
    }

    /// GPU time so far (ns) of this process's and the window server's GPU clients, from the GPU
    /// driver's user clients in the I/O Registry (`AppUsage` › `accumulatedGPUTime`).
    nonisolated static func gpuTimes() -> (own: Double, windowServer: Double) {
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(accelerators) }
        let prefix = "pid \(getpid()),"
        var own = 0.0, server = 0.0
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var clients: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &clients) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(clients) }
            while case let client = IOIteratorNext(clients), client != 0 {
                defer { IOObjectRelease(client) }
                guard let creator = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String else { continue }
                let isOwn = creator.hasPrefix(prefix), isServer = creator.hasSuffix(", WindowServer")
                guard isOwn || isServer,
                      let usage = IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                          .takeRetainedValue() as? [[String: Any]] else { continue }
                var total = 0.0
                for entry in usage { total += (entry["accumulatedGPUTime"] as? NSNumber)?.doubleValue ?? 0 }
                if isOwn { own += total } else { server += total }
            }
        }
        return (own, server)
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
