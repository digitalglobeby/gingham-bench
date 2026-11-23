//
//  ScreenMeter.swift
//  Gingham Bench
//
//  Screen truth: how often the table's pixels actually change on the screen, measured from
//  outside the engines. ScreenCaptureKit captures only the bench's window
//  (`SCContentFilter(desktopIndependentWindow:)`) at up to the display's rate, into a small
//  output (half the window's size in points), frames handled on a background queue. It delivers
//  a frame only when the window's content changed. The changed rectangles it reports for a
//  window cover the whole frame, so each frame's table body (below the window's top bar with its
//  live numbers and the column header, without the scroller strips) is compared with the
//  previous frame's, pixel row by pixel row: a frame whose table rows changed is a "screen update
//  of the table", with the share of rows that changed. This is what the eye sees, whatever an
//  engine says it did.
//
//  It needs the Screen Recording permission of the process that captures (System Settings ›
//  Privacy & Security › Screen & System Audio Recording): the bench app when opened from the
//  Finder, or the terminal app that started it from the command line. Without it the numbers are
//  null and the run says so.
//

import AppKit
import ScreenCaptureKit

nonisolated final class ScreenMeter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let data: MeterData
    private let queue = DispatchQueue(label: "Screen meter", qos: .userInitiated)
    private let lock = NSLock()
    private var stream: SCStream?
    /// The table's body in the captured frame (its pixels, origin at the top left).
    private var tableRect = CGRect.zero
    private var outputSize = CGSize.zero
    private var status = "not started"

    /// `GINGHAM_BENCH_SCREEN_DEBUG`: each frame's rectangles to stderr.
    private static let debug = ProcessInfo.processInfo.environment["GINGHAM_BENCH_SCREEN_DEBUG"] != nil

    init(data: MeterData) {
        self.data = data
    }

    /// "running", or why not (no permission, the window not found…).
    var state: String { lock.withLock { status } }

    /// Starts capturing the window; `tableBody`: the table's body in the window's content view
    /// (points, origin at the top left of the window's frame).
    @MainActor func start(window: NSWindow, tableBody: CGRect, refreshRate: Int) async {
        let windowID = CGWindowID(window.windowNumber)
        let frame = window.frame
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let captured = content.windows.first(where: { $0.windowID == windowID }) else {
                lock.withLock { status = "the bench's window wasn't among the windows ScreenCaptureKit sees" }
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: captured)
            let configuration = SCStreamConfiguration()
            // Half the window's size in points: small, and still a few pixels per row.
            let size = CGSize(width: (frame.width / 2).rounded(), height: (frame.height / 2).rounded())
            configuration.width = Int(size.width)
            configuration.height = Int(size.height)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(refreshRate, 60)))
            configuration.queueDepth = 5
            configuration.showsCursor = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            let scale = size.height / frame.height
            lock.withLock {
                outputSize = size
                tableRect = CGRect(x: tableBody.minX * scale, y: tableBody.minY * scale, width: tableBody.width * scale, height: tableBody.height * scale)
            }
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            lock.withLock {
                self.stream = stream
                status = "running"
            }
        } catch {
            let text = (error as NSError).code == SCStreamError.userDeclined.rawValue || "\(error)".contains("TCC") || "\(error)".lowercased().contains("declined")
                ? "no Screen Recording permission (System Settings › Privacy & Security › Screen & System Audio Recording: allow Gingham Bench, or the terminal app that runs it)"
                : "ScreenCaptureKit: \(error.localizedDescription)"
            lock.withLock { status = text }
        }
    }

    func stop() {
        let stream = lock.withLock { () -> SCStream? in
            defer { self.stream = nil }
            return self.stream
        }
        stream?.stopCapture { _ in }
    }

    /// The table's body in the previous frame, row after row (only this queue touches it).
    private var previous: [UInt8] = []

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()
        let table = lock.withLock { tableRect }
        // A window frame's changed rectangles cover the whole frame, so the table's rows are
        // compared with the previous frame's, pixel row by pixel row: the share of rows that
        // changed (0: only the top bar or the header changed).
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let firstRow = max(0, Int(table.minY.rounded())), lastRow = min(height, Int(table.maxY.rounded()))
        let firstColumn = max(0, Int(table.minX.rounded())), lastColumn = min(width, Int(table.maxX.rounded()))
        guard lastRow > firstRow, lastColumn > firstColumn else { return }
        let rowBytes = (lastColumn - firstColumn) * 4, rows = lastRow - firstRow
        var changed = 0
        if previous.count != rows * rowBytes {
            previous = [UInt8](repeating: 0, count: rows * rowBytes)
        }
        previous.withUnsafeMutableBytes { stored in
            guard let storedBase = stored.baseAddress else { return }
            for row in 0..<rows {
                let source = base + (firstRow + row) * bytesPerRow + firstColumn * 4
                let kept = storedBase + row * rowBytes
                if memcmp(source, kept, rowBytes) != 0 {
                    changed += 1
                    memcpy(kept, source, rowBytes)
                }
            }
        }
        if Self.debug {
            FileHandle.standardError.write(Data("screen frame: table rows \(firstRow)..<\(lastRow) of \(height), changed \(changed)\n".utf8))
        }
        data.screenFrame(at: now, tableShare: Double(changed) / Double(rows))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { status = "stopped: \(error.localizedDescription)" }
    }
}
