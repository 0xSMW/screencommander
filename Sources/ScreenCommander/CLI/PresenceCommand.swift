import ArgumentParser
import Foundation
import ScreenCommanderPresence

/// `--session` and `--no-agent-cursor`, shared by every input command.
struct AgentPresenceOptions: ParsableArguments {
    @Option(name: .long, help: "Agent session that leases the target app during background delivery. While another session holds the app, input fails with target_busy. (default: $SCREENCOMMANDER_SESSION, else 'default')")
    var session: String?

    @Flag(name: .customLong("no-agent-cursor"), help: "Do not draw the agent cursor. Same as SCREENCOMMANDER_AGENT_CURSOR=0. The session lease, the focus guard, and yielding to the user still apply.")
    var noAgentCursor: Bool = false

    /// nil leaves the choice to the process default.
    var agentCursor: Bool? {
        noAgentCursor ? false : nil
    }
}

/// Hidden: runs the presence process (agent cursor, focus guard, user-input tap,
/// abort key, leases). Input commands start it on demand; it exits after an
/// idle period, on `shutdown`, or on SIGTERM.
struct PresenceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: PresenceLaunch.subcommand,
        abstract: "Run the presence process: agent cursor, session leases, focus guard, and abort key.",
        discussion: """
            Input commands start this process on demand, so you do not run it yourself. It exits \
            after an idle period or on SIGTERM.
            """,
        shouldDisplay: false
    )

    @Option(name: .long, help: "Unix socket path. Defaults to presence.sock in the state directory.")
    var socket: String?

    @Option(name: .customLong("idle-timeout"), help: "Exit after this many seconds with no session, no focus guard, and no abort in force. Connected clients do not keep it running.")
    var idleTimeout: Double = 120

    func run() throws {
        guard idleTimeout > 0 else {
            throw ValidationError("--idle-timeout must be greater than zero.")
        }
        let statePaths = StatePaths()
        let socketPath = socket ?? PresenceLaunch.socketPath(statePaths: statePaths)
        let startErrorURL = statePaths.presenceStartErrorURL
        // Stdout and stderr go to /dev/null when a client spawns this process, so
        // failures are also written where `doctor` reads them.
        func fail(_ reason: String) -> ExitCode {
            PresenceLaunch.recordStartError(reason, at: startErrorURL, overwrite: true)
            writeError("presence: \(reason)")
            return ExitCode.failure
        }
        if let problem = PresenceLaunch.socketDirectoryProblem(socketPath: socketPath, create: true) {
            throw fail(problem)
        }
        PresenceLaunch.clearStartError(at: startErrorURL)
        let server = PresenceServer(configuration: PresenceServerConfiguration(
            socketPath: socketPath,
            idleTimeout: idleTimeout,
            keepAwake: KeepAwake.isEnabled(environment: ProcessInfo.processInfo.environment)
        ))
        do {
            try server.run()
        } catch PresenceSocketError.alreadyRunning {
            // Two clients raced to start presence; the other one won.
            return
        } catch {
            throw fail("\(error)")
        }
    }
}

struct ResumeResult: Codable, Sendable {
    /// True when a running presence process cleared its abort flag.
    var resumed: Bool
    /// `active` when the presence process answered, `unavailable` when none is running.
    var presence: ActionPresence
    /// Whether actions were stopped before this call.
    var wasAborted: Bool?
}

/// `resume`: clears the abort flag the abort key (Control-Option-Command-Period) set.
struct ResumeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resume",
        abstract: "Let agent input run again after the abort key stopped it.",
        discussion: """
            Pressing Control-Option-Command-Period stops agent input: every input action, launch, \
            and focus fails with aborted_by_user until resume runs. Check with the user before resuming.

            Example:
              screencommander resume
            """
    )

    @Flag(name: .long, help: ArgumentHelp(HelpText.json))
    var json: Bool = false

    mutating func run() throws {
        defer { OutputOptions.current = nil }
        do {
            let (format, compact) = try OutputOptions.effective(jsonFlag: json)
            OutputOptions.current = (format, compact, "resume")
            let client = PresenceLaunch.probeClient(
                socketPath: PresenceLaunch.socketPath(statePaths: StatePaths()),
                clientName: "screencommander resume"
            )
            defer { client?.disconnect() }

            let wasAborted = client?.status().value?.aborted
            let result: ResumeResult
            switch client?.resume() {
            case .success:
                result = ResumeResult(resumed: true, presence: .active, wasAborted: wasAborted)
            case .failure, .unavailable, nil:
                result = ResumeResult(resumed: false, presence: .unavailable, wasAborted: nil)
            }

            if format == .json {
                try CommandRuntime.emitJSON(command: "resume", result: result, compact: compact)
                return
            }
            if !result.resumed {
                print("Presence is not running; nothing to resume.")
            } else if result.wasAborted == true {
                print("Resumed: agent input runs again.")
            } else {
                print("Agent input was not stopped; nothing to resume.")
            }
        } catch {
            throw CommandRuntime.mapError(error)
        }
    }
}
