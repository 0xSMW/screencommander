import Foundation

/// The allowed range of every numeric input that sets a duration, a count, or a
/// text range, whether it comes from the CLI, an MCP tool call, or a sequence file.
/// The engine checks each value before it is used, so no input can overflow a
/// conversion and stop the process. A value outside its range fails with
/// `invalid_arguments` naming the range.
enum InputLimits {
    /// `drag --duration-ms` (MCP and sequence `durationMs`).
    static let dragDurationMs = 0...60_000
    /// `drag --steps`.
    static let dragSteps = 1...10_000
    /// `move --dwell-ms` (`dwellMs`).
    static let dwellMs = 0...60_000
    /// `type --delay-ms` (`delayMs`), per character.
    static let typeDelayMs = 0...10_000
    /// A `sleep:<ms>` step in `keys`.
    static let keySleepMs = 0...60_000
    /// A `sleep` step in a sequence file (`ms`).
    static let sequenceSleepMs = 0...3_600_000
    /// `observe --timeout-ms`.
    static let observeTimeoutMs = 0...86_400_000
    /// `cleanup --older-than-hours`: up to ten years.
    static let olderThanHours = 0...87_600
    /// `elements --max-value-length`.
    static let maxValueLength = 0...1_000_000
    /// `select-text --range` location and length, in UTF-16 code units.
    static let textRange = 0...Int(Int32.max)

    /// Throws `invalid_arguments` unless `value` lies in `range`.
    static func check(_ value: Int, in range: ClosedRange<Int>, _ name: String) throws {
        guard range.contains(value) else {
            throw ScreenCommanderError.invalidArguments(
                "\(name) must be between \(range.lowerBound) and \(range.upperBound), not \(value)."
            )
        }
    }
}
