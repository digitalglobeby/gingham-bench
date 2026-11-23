import QuartzCore
import UIKit

// The app's own frame meter: main-thread frame callbacks. It is the
// secondary figure; the primary ones come from the system's render server:
// the UI tests' hitch metrics (iOS/UITests) and Instruments' Animation
// Hitches (iOS/Scripts/run-device.sh --hitches).
//
// A frame here is a display link callback on the main thread. The display
// link asks for the screen's full rate (120 a second on ProMotion), so it is
// called once per screen refresh while the main thread keeps up; when the
// main thread is busy past a refresh (laying out and configuring cells,
// diffing, drawing text), the callback for that refresh is skipped: that
// refresh gets no new picture from the main thread. The time between two
// callbacks (their `timestamp`s, the refreshes' own times, not when the
// callback happened to run) is how long a picture stayed on screen as far as
// the main thread can tell.
//
// - Frames a second: callbacks during the test over its duration.
// - Worst second: the fewest callbacks in any of the test's whole seconds.
// - Longest frame: the longest time between two callbacks.
// - Hitches: frames that stayed more than 1.5 refreshes. Hitch time: how
//   much longer than one refresh they stayed, in total, in ms per second;
//   modeled on Apple's hitch time ratio, but from main-thread callbacks only.
// - Main thread busy: the share of the time the main run loop didn't wait.
//
// What this can't see: work done after the main thread hands a frame over
// (by the render server and the GPU, and by an engine's own threads or
// drawing). A frame that misses its refresh there is a hitch the user sees
// but this meter doesn't, which is why the render server's figures come first.

@MainActor
final class FrameMeter {
    struct Result {
        var frames: Int
        var duration: CFTimeInterval
        var averageFPS: Double
        var worstSecondFPS: Int
        var longestFrameMs: Double
        var hitches: Int
        var hitchTimeMsPerSecond: Double
        var mainThreadBusy: Double
        /// The refresh interval the display link was given (1/120 s on ProMotion).
        var refreshIntervalMs: Double
    }

    /// Callback times over the last second (the live readout).
    private var recent: [CFTimeInterval] = []
    private var waits: [(start: CFTimeInterval, end: CFTimeInterval)] = []
    private var waitStart: CFTimeInterval?
    private var observer: CFRunLoopObserver?
    /// The callbacks of a measured span, and how long the main thread waited in it.
    private var span: (start: CFTimeInterval, frames: [CFTimeInterval], waited: CFTimeInterval, interval: CFTimeInterval)?

    /// Watches the main run loop's waits (for the busy share).
    func start() {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue,
                                                          true, Int.max) { [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                if activity == .beforeWaiting {
                    self.waitStart = now
                } else if let start = self.waitStart {
                    self.waits.append((start, now))
                    if let from = self.span?.start { self.span?.waited += now - max(start, from) }
                    self.waitStart = nil
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    /// Called by the bench's display link on every callback.
    func frame(_ link: CADisplayLink) {
        recent.append(link.timestamp)
        guard var span else { return }
        span.frames.append(link.timestamp)
        let interval = link.targetTimestamp - link.timestamp
        if interval > 0 { span.interval = min(span.interval, interval) }
        self.span = span
    }

    /// Over the last second: frames, and the main thread's busy share (0...1).
    func lastSecond() -> (frames: Int, busy: Double) {
        let now = CACurrentMediaTime(), from = now - 1
        recent.removeAll { $0 < from }
        waits.removeAll { $0.end < from }
        var waited = waits.reduce(0) { $0 + ($1.end - max($1.start, from)) }
        if let start = waitStart { waited += now - max(start, from) }
        return (recent.count, max(0, min(1, 1 - waited)))
    }

    func beginMeasuring() {
        span = (CACurrentMediaTime(), [], 0, .infinity)
    }

    var isMeasuring: Bool { span != nil }

    func endMeasuring() -> Result? {
        guard let span = span.take(), let first = span.frames.first, let last = span.frames.last, span.frames.count > 1 else { return nil }
        let duration = last - first
        let gaps = zip(span.frames.dropFirst(), span.frames).map { $0 - $1 }
        let interval = span.interval.isFinite ? span.interval : (gaps.min() ?? 1.0 / 60)
        // Each whole second from the first frame: the fewest frames in one.
        var worst = Int.max
        var second = first
        var index = 0
        while second + 1 <= last {
            let end = second + 1
            var count = 0
            while index < span.frames.count, span.frames[index] < end {
                if span.frames[index] >= second { count += 1 }
                index += 1
            }
            worst = min(worst, count)
            second = end
        }
        let late = gaps.filter { $0 > interval * 1.5 }
        let hitchTime = late.reduce(0) { $0 + ($1 - interval) }
        let elapsed = CACurrentMediaTime() - span.start
        return Result(frames: span.frames.count - 1,
                      duration: duration,
                      averageFPS: Double(span.frames.count - 1) / duration,
                      worstSecondFPS: worst == .max ? span.frames.count - 1 : worst,
                      longestFrameMs: (gaps.max() ?? 0) * 1000,
                      hitches: late.count,
                      hitchTimeMsPerSecond: hitchTime * 1000 / duration,
                      mainThreadBusy: max(0, min(1, 1 - span.waited / elapsed)),
                      refreshIntervalMs: interval * 1000)
    }
}

extension Optional {
    /// The value, leaving `nil` behind.
    mutating func take() -> Wrapped? {
        defer { self = nil }
        return self
    }
}
