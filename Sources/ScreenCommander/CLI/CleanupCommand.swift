import ArgumentParser
import Foundation

struct CleanupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Prune managed capture artifacts older than a threshold."
    )

    @Option(name: .long, help: "Retention age in hours. Default is 24.")
    var olderThanHours: Int?

    @Flag(name: .long, help: "Emit a single machine-readable JSON object to stdout (success or error envelope). For scripting; see README.")
    var json: Bool = false

    mutating func run() throws {
        let (format, compact) = OutputOptions.effective(jsonFlag: json)
        OutputOptions.current = (format, compact, "cleanup")
        defer { OutputOptions.current = nil }
        do {
            let result = try CommandRuntime.engine.cleanup(CleanupRequest(olderThanHours: olderThanHours))

            if format == .json {
                try CommandRuntime.emitJSON(command: "cleanup", result: result, compact: compact)
                return
            }

            print("Deleted files: \(result.deletedCount)")
            print("Deleted approx bytes: \(result.deletedBytesApprox)")
        } catch {
            throw CommandRuntime.mapError(error)
        }
    }
}
