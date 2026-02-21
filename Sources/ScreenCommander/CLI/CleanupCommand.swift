import ArgumentParser
import Foundation

struct CleanupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Prune managed capture artifacts older than a threshold."
    )

    @Option(name: .long, help: "Retention age in hours. Default is 24.")
    var olderThanHours: Int?

    @Flag(name: .long, help: "Emit machine-readable JSON output.")
    var json: Bool = false

    mutating func run() throws {
        do {
            let result = try CommandRuntime.engine.cleanup(CleanupRequest(olderThanHours: olderThanHours))

            if json {
                try CommandRuntime.emitJSON(command: "cleanup", result: result)
                return
            }

            print("Deleted files: \(result.deletedCount)")
            print("Deleted approx bytes: \(result.deletedBytesApprox)")
        } catch {
            throw CommandRuntime.mapError(error)
        }
    }
}
