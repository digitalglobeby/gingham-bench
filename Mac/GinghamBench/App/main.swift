//
//  main.swift
//  Gingham Bench
//
//  An open benchmark of table views on the Mac: Gingham against NSTableView (as apps
//  typically write it, and tuned), NSCollectionView and SwiftUI's Table, on the same live data.
//  See README.md for what is measured and how; Options.swift for the launch arguments.
//

import AppKit

let options: Options
do {
    options = try Options.parse(CommandLine.arguments)
} catch {
    FileHandle.standardError.write(Data("Gingham Bench: \(error.localizedDescription)\n".utf8))
    exit(64)
}

// Before any table shows rows: the bench's key shows every row (without it, 10,000).
BenchKey.register()
GinghamEngine.showsExtras = options.ginghamExtras
SwiftUITunedEngine.diffsMoves = options.swiftUIDiffsMoves

if options.checkFormats {
    let differences = BenchFormat.differencesFromGingham()
    print(differences.isEmpty ? "Number text: the same as Gingham's." : differences.joined(separator: "\n"))
    exit(differences.isEmpty ? 0 : 1)
}

if let name = options.calibrateFeed {
    guard let model = FeedModel(rawValue: name) else { print("no feed model \(name)"); exit(64) }
    // Ticks without waiting for the clock: row changes per second of the feed's own time.
    let generator = FeedGenerator(model: model)
    var batch = FeedBatch(), changes = 0
    let seconds = 3.0
    for _ in 0..<Int(seconds / generator.tickInterval) {
        generator.tick(into: &batch)
        changes += batch.count
        batch.removeAll()
    }
    print("\(model.rawValue): \(Int(Double(changes) / seconds)) row changes a second (ticks of \(generator.tickInterval * 1000) ms)")
    exit(0)
}

if let path = options.summarize {
    let markdown = Report.markdown(Report.read(path))
    if let output = options.markdown { try? markdown.write(toFile: output, atomically: true, encoding: .utf8) } else { print(markdown) }
    exit(0)
}

if options.isMeasuring && !options.isChild {
    exit(Orchestrator.run(options))
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var child: ChildRun?
    private var interactive: InteractiveController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if options.isMeasuring {
            let ui = BenchWindow(size: options.windowSize, interactive: false)
            let run = ChildRun(options: options, ui: ui)
            child = run
            run.start()
        } else {
            let controller = InteractiveController(options: options)
            interactive = controller
            controller.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.mainMenu = {
    let menu = NSMenu()
    let appItem = NSMenuItem()
    appItem.submenu = NSMenu()
    appItem.submenu?.addItem(withTitle: "Quit Gingham Bench", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    menu.addItem(appItem)
    return menu
}()
app.run()
