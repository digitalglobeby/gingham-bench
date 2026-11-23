import Gingham

/// Gingham's free key for this open-source bench: every row shown, so that
/// the scenarios with hundreds of thousands and millions of rows run as
/// measured. It unlocks only the bundle id by.digitalglobe.gingham-bench
/// (with another, tables show up to `GHLicense.freeRowLimit` rows).
@MainActor
enum BenchKey {
    static let key = "GH1.eyJidW5kbGVzIjpbImJ5LmRpZ2l0YWxnbG9iZS5naW5naGFtLWJlbmNoIl0sImVkaXRpb24iOiJvcGVuLXNvdXJjZSIsImlkIjoiR0gtMjAyNi1PU1MtMDAwMiIsImlzc3VlZCI6IjIwMjYtMTEtMjIiLCJsaWNlbnNlZSI6IkdpbmdoYW0gQmVuY2ggKG9wZW4gc291cmNlLCBkaWdpdGFsZ2xvYmVieSkiLCJtYWpvciI6MSwidiI6MX0.tPfrjXQzCqLz-z6-JfkKgWh2WeHGC6VEfbNMg4XoL2B3D5Q5GbR6AoAJ0ztRI8qDC16T1nfOblXXoLHh0A8_CA"

    static func register() {
        GHLicense.register(key)
    }
}
