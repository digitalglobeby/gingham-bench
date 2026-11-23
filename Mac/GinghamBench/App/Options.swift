//
//  Options.swift
//  Gingham Bench
//
//  Launch arguments. Without `--scenario` the app opens its window for trying the engines by
//  hand (and recording); with it, it runs the measurement and quits:
//
//    "Gingham Bench" --scenario live-trades --engine all --seconds 10 --runs 3 --output results/run.jsonl
//
//    --scenario <id|all|live>  live-trades, order-book, trade-feed, binance-tickers, binance-books,
//                              sort-text (by pair), sort-text-account; "all"; "live" (no sorts); a comma list
//    --engine <id|all>         gingham, nstable, nstable-tuned, nstable-cells, collection, swiftui,
//                              swiftui-tuned; "all"; a comma list
//    --seconds N               measured seconds per run (10)
//    --warmup N                seconds after the rows show before measuring (3; Binance 5)
//    --runs N                  runs of each engine (3), each in a new process
//    --output PATH             JSON lines appended here; the Markdown table goes next to it (.md)
//    --rows N                  another number of rows than the scenario's
//    --binance-domain D        binance.com (or binance.us)
//    --load-timeout N          seconds an engine may take to show its rows (30)
//    --window WxH              the window's content size (1000x640)
//    --gingham-extras          Gingham also highlights changes and shows a summary row
//    --swiftui-diff-moves      the tuned SwiftUI Table gets reordered rows without a new .id (SwiftUI diffs the moves)
//    --summarize PATH          only writes the Markdown table of a JSON lines file (to --markdown or stdout)
//    --check-formats           prints where the other engines' number text differs from Gingham's
//    --calibrate-feed MODEL    prints the row changes a second a generated feed makes (trades, orders, instruments)
//    --cycle N                 window mode: switch engines every N seconds (for recording); --quit after a round
//

import AppKit

struct Options {
    var scenarios: [ScenarioID] = []
    var engines: [EngineKind] = EngineKind.allCases
    var seconds: Double = 10
    var warmup: Double?
    var runs = 3
    var run = 1
    var output: String?
    var rows: Int?
    var calibrateFeed: String?
    var binanceDomain = "binance.com"
    var loadTimeout: Double = 30
    var windowSize = NSSize(width: 1000, height: 640)
    var ginghamExtras = false
    var swiftUIDiffsMoves = false
    var summarize: String?
    var markdown: String?
    var checkFormats = false
    var cycle: Double?
    var quitAfterCycle = false
    var isChild = false
    var initialScenario: ScenarioID = .liveTrades
    var initialEngine: EngineKind = .gingham

    func warmup(for scenario: ScenarioID) -> Double { warmup ?? (scenario.isLiveMarket ? 5 : 3) }

    /// Measuring from the command line (not the window).
    var isMeasuring: Bool { !scenarios.isEmpty }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 1
        func value(_ name: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw ScenarioError("\(name) needs a value") }
            return arguments[index]
        }
        func number(_ name: String) throws -> Double {
            let text = try value(name)
            guard let number = Double(text) else { throw ScenarioError("\(name): \(text) isn't a number") }
            return number
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--scenario":
                let text = try value(argument)
                switch text {
                case "all": options.scenarios = ScenarioID.allCases
                case "live": options.scenarios = ScenarioID.allCases.filter { !$0.isSort }
                default:
                    options.scenarios = try text.split(separator: ",").map {
                        guard let id = ScenarioID(rawValue: String($0)) else { throw ScenarioError("no scenario \($0)") }
                        return id
                    }
                }
            case "--engine":
                let text = try value(argument)
                options.engines = text == "all" ? EngineKind.allCases : try text.split(separator: ",").map {
                    guard let kind = EngineKind(rawValue: String($0)) else { throw ScenarioError("no engine \($0)") }
                    return kind
                }
            case "--seconds": options.seconds = try number(argument)
            case "--warmup": options.warmup = try number(argument)
            case "--runs": options.runs = max(1, Int(try number(argument)))
            case "--run": options.run = Int(try number(argument))
            case "--output": options.output = try value(argument)
            case "--rows": options.rows = Int(try number(argument))
            case "--calibrate-feed": options.calibrateFeed = try value(argument)
            case "--binance-domain": options.binanceDomain = try value(argument)
            case "--load-timeout": options.loadTimeout = try number(argument)
            case "--window":
                let parts = try value(argument).split(separator: "x").compactMap { Double($0) }
                guard parts.count == 2 else { throw ScenarioError("--window WxH") }
                options.windowSize = NSSize(width: parts[0], height: parts[1])
            case "--gingham-extras": options.ginghamExtras = true
            case "--swiftui-diff-moves": options.swiftUIDiffsMoves = true
            case "--summarize": options.summarize = try value(argument)
            case "--markdown": options.markdown = try value(argument)
            case "--check-formats": options.checkFormats = true
            case "--cycle": options.cycle = try number(argument)
            case "--quit": options.quitAfterCycle = true
            case "--child": options.isChild = true
            case "--show":
                // Window mode: the scenario and engine to open with.
                let parts = try value(argument).split(separator: "/")
                if let first = parts.first, let id = ScenarioID(rawValue: String(first)) { options.initialScenario = id }
                if parts.count > 1, let kind = EngineKind(rawValue: String(parts[1])) { options.initialEngine = kind }
            default:
                // Arguments AppKit and Xcode add (-NSDocumentRevisionsDebugMode YES and the like).
                if argument.hasPrefix("-"), !argument.hasPrefix("--") { index += 1 }
            }
            index += 1
        }
        return options
    }

    /// The arguments of a child process measuring one scenario, engine and run.
    func childArguments(scenario: ScenarioID, engine: EngineKind, run: Int, output: String) -> [String] {
        var arguments = ["--child", "--scenario", scenario.rawValue, "--engine", engine.rawValue, "--run", String(run),
                         "--seconds", String(seconds), "--output", output, "--load-timeout", String(loadTimeout),
                         "--window", "\(Int(windowSize.width))x\(Int(windowSize.height))",
                         "--binance-domain", binanceDomain, "-ApplePersistenceIgnoreState", "YES"]
        if let warmup { arguments += ["--warmup", String(warmup)] }
        if let rows { arguments += ["--rows", String(rows)] }
        if ginghamExtras { arguments.append("--gingham-extras") }
        if swiftUIDiffsMoves { arguments.append("--swiftui-diff-moves") }
        return arguments
    }
}
