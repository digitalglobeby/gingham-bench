import CoreGraphics
import Foundation

// How a test moves the table: where its content is at each moment. Speeds are
// for rows of 24 points; an engine whose rows are taller (SwiftUI Table's) is
// moved faster in points by the same factor, so every engine brings the same
// rows a second onto the screen.
//
// - steady: down at a constant speed (3,000 points a second, 125 rows) for
//   half the test, then back up.
// - fast: the same at 8,000 points a second (333 rows).
// - flicks: a flick every second, four down and four back up, each starting
//   at 8,000 points a second and slowing down like UIScrollView's normal
//   deceleration (its velocity falls by 0.2% a millisecond), as when a user
//   flicks again and again.
//
// Real touches and UIKit's own deceleration are measured separately, by the
// UI tests (iOS/UITests).

enum ScrollProfile: String, CaseIterable, Codable {
    case steady, fast, flicks

    var title: String {
        switch self {
        case .steady: "steady scroll"
        case .fast: "fast scroll"
        case .flicks: "flicks"
        }
    }

    /// UIScrollView's normal deceleration: velocity × 0.998 a millisecond,
    /// an exponential decay with this time constant (seconds).
    static let decelerationTimeConstant = -0.001 / log(0.998)

    /// How far below the top the content is `t` seconds into a test of
    /// `duration` seconds; `scale` is the rows' height over 24 points.
    func offset(at t: TimeInterval, duration: TimeInterval, steadySpeed: CGFloat, fastSpeed: CGFloat, scale: CGFloat) -> CGFloat {
        let t = min(max(0, t), duration)
        switch self {
        case .steady, .fast:
            let speed = (self == .steady ? steadySpeed : fastSpeed) * scale
            let half = duration / 2
            return speed * CGFloat(t < half ? t : duration - t)
        case .flicks:
            // An even number of flicks of about a second each.
            let count = max(2, Int((duration / 2).rounded()) * 2)
            let length = duration / Double(count)
            let tau = Self.decelerationTimeConstant
            let v0 = Double(fastSpeed * scale)
            func travelled(_ u: TimeInterval) -> Double { v0 * tau * (1 - exp(-u / tau)) }
            let full = travelled(length)
            let index = min(count - 1, Int(t / length))
            let u = t - Double(index) * length
            let half = count / 2
            let y = index < half ? Double(index) * full + travelled(u) : Double(count - index) * full - travelled(u)
            return CGFloat(max(0, y))
        }
    }
}
