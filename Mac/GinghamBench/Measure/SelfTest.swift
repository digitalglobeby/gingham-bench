//
//  SelfTest.swift
//  Gingham Bench
//
//  `--self-test`: a deterministic replay, without the network or a window, of what the order
//  book scenarios do to an engine (Binance's `binance-books`, the hardest for the engines'
//  bookkeeping): books loaded before the engine is attached, then batches of level changes,
//  new levels at the end, levels leaving (the last row moved into their place), and book reloads
//  in batches of their own (as a snapshot that comes back from REST does). After the replay each
//  engine's order is checked against the store. A second replay changes the store behind the
//  engine's back once (the bug a book reload arriving before the engine was attached caused) and
//  checks the engine notices, rebuilds its rows and reports it instead of crashing.
//

import AppKit

enum SelfTest {
    static func run() -> Int32 {
        var failures = 0
        for kind in EngineKind.allCases {
            let normal = replay(kind, behindTheBack: false)
            print("\(kind.title): \(normal ?? "ok")")
            if normal != nil { failures += 1 }
            // (Gingham is told the same as the others; the second replay tests the bench's own
            // engines, whose bookkeeping is the bench's code.)
            guard kind != .gingham else { continue }
            let (behind, rebuilt) = replayBehindTheBack(kind)
            let expected = (behind == nil || behind?.hasPrefix("the engine lost step") == true) && rebuilt == nil
            print("\(kind.title), a change behind its back: \(behind ?? "ok (the change didn't affect it)"); order after: \(rebuilt ?? "ok")\(expected ? "" : "  ✗")")
            if !expected { failures += 1 }
        }
        print(failures == 0 ? "✓ self-test passed" : "✗ \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    private static func levels(_ random: inout SeededRandom, mid: Double, count: Int, isBid: Bool) -> [BinanceDepth.Level] {
        (0..<count).map { index in
            BinanceDepth.Level(price: mid + (isBid ? -1 : 1) * Double(index + 1) * 0.01, quantity: 0.001 + random.uniform() * 5)
        }
    }

    /// The order check as reported, and the order itself checked ignoring the lost step.
    private static func replayBehindTheBack(_ kind: EngineKind) -> (String?, String?) {
        var allowing: String?
        let reported = replay(kind, behindTheBack: true) { engine, store in
            allowing = ChildRun.checkOrder(engine, source: store, sort: store.sort, allowingDesyncs: true)
        }
        return (reported, allowing)
    }

    /// What's wrong after the replay, or nil.
    private static func replay(_ kind: EngineKind, behindTheBack: Bool, after: ((Engine, BinanceStore) -> Void)? = nil) -> String? {
        var random = SeededRandom(seed: 99)
        let store = BinanceStore(mode: .depth)
        let symbols = ["AAAUSDT", "BBBUSDT", "CCCUSDT"]
        let mids = [100.0, 20.0, 3.0]
        // The books before the engine comes (the scenario's preparation).
        for (symbol, mid) in zip(symbols, mids) {
            store.apply(levels: levels(&random, mid: mid, count: 300, isBid: true), isBid: true, symbol: symbol, time: 1)
            store.apply(levels: levels(&random, mid: mid, count: 300, isBid: false), isBid: false, symbol: symbol, time: 1)
        }
        store.flushUpdates()
        let engine = kind.make()
        store.engine = engine
        engine.load(store, sort: store.sort)
        for step in 0..<240 {
            let book = random.below(symbols.count)
            if behindTheBack, step == 100 {
                // New levels the engine isn't told about.
                store.engine = nil
                store.apply(levels: [BinanceDepth.Level(price: mids[book] + 9.99, quantity: 1)], isBid: false, symbol: symbols[book], time: 2)
                store.flushUpdates()
                store.engine = engine
            }
            if step % 40 == 20 {
                // A book loaded again, in a batch of its own.
                engine.beginUpdates()
                store.removeLevels(of: symbols[book])
                store.apply(levels: levels(&random, mid: mids[book], count: 300, isBid: true), isBid: true, symbol: symbols[book], time: Int64(step))
                store.apply(levels: levels(&random, mid: mids[book], count: 300, isBid: false), isBid: false, symbol: symbols[book], time: Int64(step))
                store.flushUpdates()
                engine.endUpdates()
                continue
            }
            engine.beginUpdates()
            for _ in 0..<25 {
                let isBid = random.below(2) == 0
                // Prices past the loaded levels make new rows; a quantity of 0 removes a level.
                let price = mids[book] + (isBid ? -1 : 1) * Double(1 + random.below(360)) * 0.01
                let quantity = random.uniform() < 0.3 ? 0 : random.uniform() * 5
                store.apply(levels: [BinanceDepth.Level(price: price, quantity: quantity)], isBid: isBid, symbol: symbols[book], time: Int64(step))
            }
            store.flushUpdates()
            engine.endUpdates()
        }
        // Background work (Gingham's live sort) has its turn.
        let deadline = Date().addingTimeInterval(10)
        repeat { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } while engine.isSorting && Date() < deadline
        after?(engine, store)
        return ChildRun.checkOrder(engine, source: store, sort: store.sort)
    }
}
