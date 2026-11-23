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
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(updates count: Int, busy share: Double, callbacks: Int, age: Double?, refreshRate: Int) {
        frames.stringValue = "\(count) updates applied/s"
        busy.stringValue = "main thread \(Int((share * 100).rounded()))% busy"
        small.stringValue = (age.map { "data age \(Int(($0 * 1000).rounded())) ms · " } ?? "") + "\(callbacks) callbacks/s"
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

final class BenchWindow {
    let window: NSWindow
    let bar: Bar
    let container = NSView()

    init(size: NSSize, interactive: Bool) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: size.width, height: size.height + 80)),
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
        // displays are attached), in front of other windows: a covered window isn't drawn.
        if let screen = NSScreen.screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }) {
            let area = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
        }
        window.level = .floating
    }

    func show() {
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// An engine's view in the container (the one before goes).
    func show(_ view: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }
}
