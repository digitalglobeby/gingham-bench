//
//  BenchWindow.swift
//  Gingham Bench
//
//  The window: a bar with the engine shown, its frames a second and how busy the main thread
//  is, over the table (like the comparison window of Gingham's README). In window mode the bar
//  has the scenario and engine menus; measuring from the command line it shows the run.
//

import AppKit

final class Bar: NSView {
    let engine = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let frames = NSTextField(labelWithString: "")
    let busy = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    /// Data age and callbacks a second.
    let small = NSTextField(labelWithString: "")
    let controls = NSStackView()
    /// Over the numbers while the main thread is stuck (window mode).
    let stall = StallBadge()
    private let stallHost = NSView()

    init(interactive: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        engine.font = .systemFont(ofSize: 28, weight: .bold)
        for label in [detail, subtitle, small] {
            label.font = .systemFont(ofSize: 13)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        for label in [frames, busy] {
            label.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
            label.alignment = .right
        }
        subtitle.alignment = .right
        small.alignment = .right
        small.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        controls.spacing = 8
        let left = NSStackView(views: interactive ? [engine, controls] : [engine, detail])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 4
        let numbers = NSStackView(views: [frames, busy])
        numbers.spacing = 28
        let right = NSStackView(views: [numbers, small, subtitle])
        right.orientation = .vertical
        right.alignment = .trailing
        right.spacing = 2
        for view in [left, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        right.setContentCompressionResistancePriority(.required, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 20),
        ])
        // A layer-hosting view: its layers are the badge's, changed from the badge's thread.
        stallHost.layer = stall.layer
        stallHost.wantsLayer = true
        stallHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stallHost)
        NSLayoutConstraint.activate([
            stallHost.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            stallHost.trailingAnchor.constraint(equalTo: busy.trailingAnchor),
            stallHost.topAnchor.constraint(equalTo: numbers.topAnchor),
            stallHost.bottomAnchor.constraint(equalTo: small.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        stall.setScale(window?.backingScaleFactor ?? 2)
    }

    /// `screen`: the table's frames with new data a second, the frames whose picture of the table
    /// changed (nil without the screen meter: the big number is then the updates applied).
    func update(updates applied: Int, busy share: Double, callbacks: Int, age: Double?, screen: Int?, refreshRate: Int) {
        let count = screen ?? applied
        frames.stringValue = screen != nil ? "\(count) frames with new data/s" : "\(count) updates applied/s"
        busy.stringValue = "main thread \(Int((share * 100).rounded()))% busy"
        small.stringValue = (screen != nil ? "\(applied) updates applied/s · " : "")
            + (age.map { "data age \(Int(($0 * 1000).rounded())) ms · " } ?? "") + "\(callbacks) callbacks/s"
        let rate = max(refreshRate, 60)
        frames.textColor = count >= rate * 5 / 6 ? .systemGreen : count >= rate / 3 ? .systemOrange : .systemRed
        busy.textColor = share < 0.75 ? .systemGreen : share < 0.9 ? .systemOrange : .systemRed
    }

    func clearNumbers() {
        frames.stringValue = ""
        busy.stringValue = ""
        small.stringValue = ""
    }
}

/// "main thread stuck for 4.2 s" over the bar's numbers. The main thread draws the numbers, so
/// while it's stuck they stay as they were (and when it comes back, the last second's are the
/// burst of updates it catches up on): a thread of its own shows this instead, through Core
/// Animation, which puts layers on the screen without the main thread. That thread is the only one
/// that changes the text and `panel.isHidden`; the main thread only sets the scale.
nonisolated final class StallBadge: @unchecked Sendable {
    let layer = CALayer()
    private let panel = CALayer()
    private let title = CATextLayer()
    private let note = CATextLayer()

    init() {
        panel.isHidden = true
        panel.backgroundColor = NSColor.windowBackgroundColor.cgColor
        title.font = NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        title.fontSize = 22
        title.foregroundColor = NSColor.systemRed.cgColor
        note.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        note.fontSize = 12
        note.foregroundColor = NSColor.secondaryLabelColor.cgColor
        for text in [title, note] {
            text.alignmentMode = .right
            text.truncationMode = .end
            panel.addSublayer(text)
        }
        layer.addSublayer(panel)
    }

    /// Main thread: the screen's scale for the text.
    func setScale(_ scale: CGFloat) {
        title.contentsScale = scale
        note.contentsScale = scale
    }

    /// The badge's thread: shows the lines (nil: hides the badge) and puts them on the screen now,
    /// laid out for the host layer's size as it is (AppKit sets it on the main thread).
    func show(_ lines: (title: String, note: String)?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let lines {
            // The panel reaches past the numbers (into the bar's margin at the right): while the
            // main thread lays the bar out again, the numbers' frames and these bounds can differ.
            let bounds = layer.bounds
            panel.frame = CGRect(x: -8, y: 0, width: bounds.width + 28, height: bounds.height + 2)
            title.frame = CGRect(x: 0, y: bounds.height - 28, width: bounds.width + 8, height: 28)
            note.frame = CGRect(x: 0, y: 0, width: bounds.width + 8, height: 16)
            title.string = lines.title
            note.string = lines.note
        }
        panel.isHidden = lines == nil
        CATransaction.commit()
        CATransaction.flush()
    }
}

/// A window AppKit doesn't fit onto the screen: `--window 3840x2160` on a smaller screen keeps its
/// size (the table lays out and draws all of it; the screen shows the top left).
final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class BenchWindow {
    let window: NSWindow
    let bar: Bar
    let container = NSView()

    init(size: NSSize, interactive: Bool) {
        window = UnconstrainedWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: size.width, height: size.height + 80)),
                          styleMask: interactive ? [.titled, .closable, .miniaturizable, .resizable] : [.titled],
                          backing: .buffered, defer: false)
        window.title = "Gingham Bench"
        window.isReleasedWhenClosed = false
        bar = Bar(interactive: interactive)
        let content = NSView()
        for view in [bar, container] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 80),
            container.topAnchor.constraint(equalTo: bar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        // On the display with the most refreshes a second (a MacBook's 120 Hz one when 60 Hz
        // displays are attached) or the one `--screen` names, in front of other windows: a covered
        // window isn't drawn.
        let named = options.screenName.flatMap { name in NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains(name) } }
        if let screen = named ?? NSScreen.screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }) {
            let area = screen.visibleFrame
            if window.frame.width > area.width || window.frame.height > area.height {
                // Larger than the screen: its top left at the screen's, so the table's top left shows.
                window.setFrameTopLeftPoint(NSPoint(x: area.minX, y: area.maxY))
            } else {
                window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
            }
        }
        // No window state saved: AppKit would write it about 11 s into a run (its persistent UI
        // flush), holding the main thread 15–20 ms, a frame of every engine.
        window.isRestorable = false
        window.level = .floating
        // Also over an app in full screen (in its own Space a new window would open behind it).
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// The table's size for `--window fill`: the display's visible area (the one `--screen` names,
    /// or the one with the most refreshes a second) less the window's title bar and the bar.
    static func fillingSize(screenName: String?) -> NSSize {
        let named = screenName.flatMap { name in NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains(name) } }
        guard let screen = named ?? NSScreen.screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }) else {
            return NSSize(width: 1000, height: 640)
        }
        let area = screen.visibleFrame
        let titleBar = NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled]).height
        return NSSize(width: area.width.rounded(.down), height: (area.height - titleBar - 80).rounded(.down))
    }

    func show() {
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The table's body in the window (points, origin at the top left of the window's frame): the
    /// container less the column header (30 points) and the scrollers' strips (16 points at the
    /// right and bottom: overlay scrollers flash when the number of rows changes), what the screen
    /// meter watches.
    var tableBody: CGRect {
        let inWindow = container.convert(container.bounds, to: nil)
        let header: CGFloat = 30, scroller: CGFloat = 16
        return CGRect(x: inWindow.minX, y: window.frame.height - inWindow.maxY + header, width: max(0, inWindow.width - scroller),
                      height: max(0, inWindow.height - header - scroller))
    }

    /// An engine's view in the container (the one before goes).
    func show(_ view: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }
}
