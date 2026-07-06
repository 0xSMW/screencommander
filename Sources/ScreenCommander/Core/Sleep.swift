import Foundation

/// Millisecond sleep that is safe for arbitrarily large values.
///
/// `usleep` takes microseconds as a `useconds_t` (UInt32), so a naive
/// `useconds_t(ms * 1_000)` traps for ms > ~4,294,967 — attacker-ish input for
/// values decoded from sequence files. Sleeping in UInt32-safe chunks keeps any
/// non-negative `Int` millisecond value spec-legal without crashing the process.
enum SleepTimer {
    /// Maximum chunk, in milliseconds, whose microsecond equivalent fits in UInt32.
    static let maxChunkMilliseconds = UInt64(UInt32.max / 1_000)

    static func sleep(milliseconds: Int) {
        guard milliseconds > 0 else { return }
        var remainingMS = UInt64(milliseconds)
        while remainingMS > 0 {
            let chunkMS = Swift.min(remainingMS, maxChunkMilliseconds)
            usleep(useconds_t(chunkMS * 1_000))
            remainingMS -= chunkMS
        }
    }
}
