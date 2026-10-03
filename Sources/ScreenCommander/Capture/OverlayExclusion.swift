import CoreGraphics
import Foundation
import ScreenCommanderPresence

/// One on-screen window, as the window server lists it right now.
struct OverlayWindowCandidate: Equatable, Sendable {
    var windowID: CGWindowID
    var ownerPID: pid_t
    var title: String?
}

/// Picks the agent-cursor windows out of the on-screen window list so display
/// captures can exclude them. A window counts when the presence process reports
/// it, when the presence process owns it (that process draws nothing else), or
/// when it carries the cursor window's title (a fallback for when presence does
/// not answer).
enum OverlayExclusion {
    /// Title of `CursorWindow` in `ScreenCommanderPresence`.
    static let cursorWindowTitle = "ScreenCommander Cursor"

    static func select(
        onScreen candidates: [OverlayWindowCandidate],
        presenceServerPID: pid_t?,
        reportedWindowIDs: [UInt32]
    ) -> Set<CGWindowID> {
        let reported = Set(reportedWindowIDs.map { CGWindowID($0) })
        return Set(candidates.compactMap { candidate in
            if reported.contains(candidate.windowID)
                || (presenceServerPID.map { $0 > 0 && $0 == candidate.ownerPID } ?? false)
                || candidate.title == cursorWindowTitle {
                return candidate.windowID
            }
            return nil
        })
    }

    /// True when a shareable-content snapshot is missing an overlay window that is
    /// on screen now, so it predates the cursor and must be refreshed before the
    /// window can be excluded.
    static func needsRefresh(overlayWindowIDs: Set<CGWindowID>, contentWindowIDs: Set<CGWindowID>) -> Bool {
        !overlayWindowIDs.isSubset(of: contentWindowIDs)
    }

    /// On-screen windows from `CGWindowListCopyWindowInfo`, which is never cached.
    static func liveOnScreenCandidates() -> [OverlayWindowCandidate] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let pid = info[kCGWindowOwnerPID as String] as? NSNumber else {
                return nil
            }
            return OverlayWindowCandidate(
                windowID: number.uint32Value,
                ownerPID: pid.int32Value,
                title: info[kCGWindowName as String] as? String
            )
        }
    }
}

/// Finds the agent-cursor windows on screen right now.
protocol OverlayWindowLocating {
    func overlayWindowIDs() async -> Set<CGWindowID>
}

struct NoOverlayWindows: OverlayWindowLocating {
    func overlayWindowIDs() async -> Set<CGWindowID> { [] }
}

/// Asks a running presence process for its overlay windows and owner pid (never
/// starting one), then matches them against the live on-screen window list.
final class PresenceOverlayLocator: OverlayWindowLocating, @unchecked Sendable {
    private let socketPath: String
    private let onScreenCandidates: () -> [OverlayWindowCandidate]

    init(
        statePaths: StatePaths,
        onScreenCandidates: @escaping () -> [OverlayWindowCandidate] = OverlayExclusion.liveOnScreenCandidates
    ) {
        self.socketPath = PresenceLaunch.socketPath(statePaths: statePaths)
        self.onScreenCandidates = onScreenCandidates
    }

    func overlayWindowIDs() async -> Set<CGWindowID> {
        let candidates = onScreenCandidates()
        // A fresh probe per capture re-checks the socket directory every time.
        var status: PresenceStatus?
        if FileManager.default.fileExists(atPath: socketPath),
           let client = PresenceLaunch.probeClient(socketPath: socketPath, clientName: "screencommander capture") {
            status = await client.status().value
            client.disconnect()
        }
        return OverlayExclusion.select(
            onScreen: candidates,
            presenceServerPID: status?.serverPID,
            reportedWindowIDs: status?.overlayWindowIDs ?? []
        )
    }
}
