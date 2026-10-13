import ArgumentParser
import Dispatch
import Foundation

struct ObserveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "observe",
        abstract: "Stream an app's UI change events as JSON lines.",
        discussion: """
            Prints one JSON object per line as events arrive, until Ctrl-C, --timeout-ms, or a match \
            for --until. A match prints a final {"matched": true, "element": ...} line. Errors are \
            JSON envelopes too.

            Example:
              screencommander observe --app TextEdit --until role=AXSheet --timeout-ms 5000
            """
    )

    @Option(name: .long, help: ArgumentHelp(HelpText.appName))
    var app: String

    @Option(name: .long, help: "Event kinds to stream, comma-separated: value, focus, window, destroy, app. (default: all)")
    var events: String?

    @Option(name: .long, help: "Stop when an element matches this predicate, such as 'role=AXButton title~=Save'. Keys: role, title, value, id. = is exact, ~= is a case-insensitive substring. id matches only elements present when observe starts.")
    var until: String?

    @Option(name: .customLong("timeout-ms"), help: "Stop after this many milliseconds and exit 0, or exit 73 (observe_timeout) when --until has not matched.")
    var timeoutMs: Int?

    @Flag(name: .long, help: "No effect: observe always prints one compact JSON object per line.")
    var json: Bool = false

    mutating func run() throws {
        // observe always streams one-line JSON; --json is a no-op accepted for
        // consistency. Register the command for JSON error envelopes on failure.
        OutputOptions.current = (.json, true, "observe")
        defer { OutputOptions.current = nil }

        do {
            let kinds = try ObservedEventKind.parseList(events)
            let predicate = try until.map { try ObservePredicate.parse($0) }
            let request = ObserveRequest(
                appIdentifier: app,
                kinds: kinds,
                timeoutMS: timeoutMs,
                predicate: predicate
            )

            let outcome = try runObserve(request)

            switch outcome {
            case .matched(let element):
                Self.emitLine(try ObserveMatch(element: element).ndjsonLine())
            case .timedOutUnmet:
                throw ScreenCommanderError.observeTimeout(
                    "--until predicate was not met within \(timeoutMs ?? 0) ms."
                )
            case .timedOut, .interrupted, .completed:
                break
            }
        } catch {
            throw CommandRuntime.mapError(error)
        }
    }

    /// Bridges the async engine stream to the synchronous CLI entry point. Blocks the
    /// calling thread until the session ends (interrupt, timeout, match, or source end);
    /// SIGINT cancels the session and exits 0.
    private func runObserve(_ request: ObserveRequest) throws -> ObserveOutcome {
        let semaphore = DispatchSemaphore(value: 0)
        let box = OutcomeBox()

        let task = Task {
            do {
                let outcome = try await CommandRuntime.engine.observe(request) { event in
                    Self.emitEvent(event)
                }
                box.value = .success(outcome)
            } catch {
                box.value = .failure(error)
            }
            semaphore.signal()
        }

        // Trap SIGINT so Ctrl-C ends the stream cleanly (exit 0) instead of killing
        // the process with 130.
        let previous = signal(SIGINT, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        signalSource.setEventHandler { task.cancel() }
        signalSource.resume()

        semaphore.wait()

        signalSource.cancel()
        signal(SIGINT, previous)

        switch box.value {
        case .success(let outcome):
            return outcome
        case .failure(let error):
            throw error
        case .none:
            return .completed
        }
    }

    private static func emitEvent(_ event: ObservedEvent) {
        guard let line = try? event.ndjsonLine() else { return }
        emitLine(line)
    }

    /// Writes one NDJSON line and flushes immediately so consumers see events live.
    private static func emitLine(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

/// Thread-safe hand-off of the observe outcome from the async Task to the blocking CLI
/// thread. The semaphore establishes the happens-before ordering around the single
/// write/read, so a plain box suffices.
private final class OutcomeBox: @unchecked Sendable {
    var value: Result<ObserveOutcome, Error>?
}
