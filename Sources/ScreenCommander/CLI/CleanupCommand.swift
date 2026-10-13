import ArgumentParser
import Foundation

struct CleanupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Delete managed captures older than a given age.",
        discussion: """
            Deletes .png, .jpeg, .jpg, and .json files in ~/Library/Caches/screencommander/captures. \
            It keeps last-screenshot.json and files saved elsewhere with --out.

            Example:
              screencommander cleanup --older-than-hours 2
            """
    )

    @Option(name: .long, help: "Delete captures older than this many hours. (default: 24)")
    var olderThanHours: Int?

    @Flag(name: .long, help: ArgumentHelp(HelpText.json))
    var json: Bool = false

    mutating func run() throws {
        defer { OutputOptions.current = nil }
        do {
            let (format, compact) = try OutputOptions.effective(jsonFlag: json)
            OutputOptions.current = (format, compact, "cleanup")
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
