import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCommanderPresence

struct DoctorPermissionStatus: Codable, Sendable {
    var screenRecordingGranted: Bool
    var accessibilityGranted: Bool
}

struct DoctorDisplayStatus: Codable, Sendable {
    var displayID: UInt32
    var isMain: Bool
    var boundsPoints: RectD
}

/// The presence process as `doctor` sees it. Doctor never starts it.
struct DoctorPresenceStatus: Codable, Sendable {
    var running: Bool
    var socketPath: String
    var serverPID: Int32?
    /// False when the user-input tap could not start (Accessibility or Input
    /// Monitoring missing): yielding to the user and the abort key do not work.
    var tapAvailable: Bool?
    /// True after the abort key; actions fail with `aborted_by_user` until `resume`.
    var aborted: Bool?
    var sessions: [SessionStatus]?
    var overlayWindowIDs: [UInt32]?
    /// Whether presence holds its display-awake assertion right now. Nil when
    /// keep-awake is off in that process or presence is an older build.
    var keepAwake: Bool?
    /// False when `SCREENCOMMANDER_KEEP_AWAKE=0` turns keep-awake off for this process.
    var keepAwakeEnabled: Bool = KeepAwake.isEnabled(environment: ProcessInfo.processInfo.environment)
    /// Why presence could not be queried, when it is not running.
    var detail: String?
    /// False when `SCREENCOMMANDER_PRESENCE=0` turns presence off.
    var enabled: Bool = true
    /// Why presence could not start, when it is not running: a socket directory
    /// problem, or the error recorded by the last failed start.
    var startError: String?

    init(socketPath: String, reply: PresenceReply<PresenceStatus>) {
        self.socketPath = socketPath
        switch reply {
        case .success(let status):
            running = true
            serverPID = status.serverPID
            tapAvailable = status.tapAvailable
            aborted = status.aborted
            sessions = status.sessions
            overlayWindowIDs = status.overlayWindowIDs
            keepAwake = status.keepAwake
        case .failure(let error):
            running = true
            detail = error.message
        case .unavailable(let reason):
            running = false
            detail = reason
        }
    }
}

struct DoctorReport: Codable, Sendable {
    var permissions: DoctorPermissionStatus
    var displays: [DoctorDisplayStatus]
    /// Private symbols the background delivery tiers resolve at runtime.
    var privateAPIs: [PrivateAPI.SymbolStatus] = []
    var presence: DoctorPresenceStatus? = nil
    /// `doctor --app`: the app's delivery profile. Classification reads the bundle only.
    var appProfile: AppProfileReport? = nil
}

protocol DoctorReporting {
    func collect() throws -> DoctorReport
}

struct DoctorService: DoctorReporting {
    var presence: () -> DoctorPresenceStatus = DoctorService.livePresence

    /// Asks a running presence process for its state without starting one.
    static func livePresence() -> DoctorPresenceStatus {
        let statePaths = StatePaths()
        let socketPath = PresenceLaunch.socketPath(statePaths: statePaths)
        guard PresenceSettings.presenceEnabled() else {
            var status = DoctorPresenceStatus(socketPath: socketPath, reply: .unavailable("Disabled by SCREENCOMMANDER_PRESENCE=0."))
            status.enabled = false
            return status
        }
        if let problem = PresenceLaunch.socketDirectoryProblem(socketPath: socketPath, create: false) {
            var status = DoctorPresenceStatus(socketPath: socketPath, reply: .unavailable(problem))
            status.startError = problem
            return status
        }
        var status: DoctorPresenceStatus
        if FileManager.default.fileExists(atPath: socketPath),
           let client = PresenceLaunch.probeClient(socketPath: socketPath, clientName: "screencommander doctor") {
            defer { client.disconnect() }
            status = DoctorPresenceStatus(socketPath: socketPath, reply: client.status())
        } else {
            status = DoctorPresenceStatus(socketPath: socketPath, reply: .unavailable("Not running (no socket)."))
        }
        if !status.running {
            status.startError = PresenceLaunch.readStartError(at: statePaths.presenceStartErrorURL)
        }
        return status
    }

    func collect() throws -> DoctorReport {
        let permissions = DoctorPermissionStatus(
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            accessibilityGranted: AXIsProcessTrusted()
        )

        var count: UInt32 = 0
        let countStatus = CGGetActiveDisplayList(0, nil, &count)
        guard countStatus == .success else {
            throw ScreenCommanderError.captureFailed("Could not query active display count (\(countStatus.rawValue)).")
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let listStatus = CGGetActiveDisplayList(count, &displayIDs, &count)
        guard listStatus == .success else {
            throw ScreenCommanderError.captureFailed("Could not query active displays (\(listStatus.rawValue)).")
        }

        let mainID = CGMainDisplayID()
        let displays = displayIDs.map { displayID in
            DoctorDisplayStatus(
                displayID: displayID,
                isMain: displayID == mainID,
                boundsPoints: RectD(CGDisplayBounds(displayID))
            )
        }

        return DoctorReport(
            permissions: permissions,
            displays: displays,
            privateAPIs: PrivateAPI.symbolReport(),
            presence: presence()
        )
    }
}
