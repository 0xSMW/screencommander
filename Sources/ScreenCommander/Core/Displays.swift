import CoreGraphics
import Foundation
import ScreenCaptureKit

struct ResolvedDisplay {
    let displayID: UInt32
    let displayFramePoints: CGRect
    let scDisplay: SCDisplay
    /// Agent-cursor windows the capture leaves out.
    var excludedWindows: [SCWindow] = []
}

protocol DisplayResolving {
    func resolveDisplay(identifier: String) async throws -> ResolvedDisplay
}

final class Displays: DisplayResolving {
    private let contentProvider: ShareableContentProvider
    private let overlayWindows: OverlayWindowLocating

    init(
        contentProvider: ShareableContentProvider = ShareableContentProvider(),
        overlayWindows: OverlayWindowLocating = NoOverlayWindows()
    ) {
        self.contentProvider = contentProvider
        self.overlayWindows = overlayWindows
    }

    func resolveDisplay(identifier: String) async throws -> ResolvedDisplay {
        var content: SCShareableContent
        let overlayIDs: Set<CGWindowID>
        do {
            async let overlays = overlayWindows.overlayWindowIDs()
            content = try await contentProvider.content(onScreenWindowsOnly: true)
            overlayIDs = await overlays
            // A warm cache can predate the agent cursor's window. Refresh so the
            // window can be excluded instead of captured.
            if !CaptureGeometry.displaysAreCurrent(content.displays)
                || OverlayExclusion.needsRefresh(
                    overlayWindowIDs: overlayIDs,
                    contentWindowIDs: Set(content.windows.map(\.windowID))
                ) {
                content = try await contentProvider.content(onScreenWindowsOnly: true, forceRefresh: true)
            }
        } catch let error as ScreenCommanderError {
            throw error
        } catch {
            throw ScreenCommanderError.captureFailed("Could not enumerate displays: \(error.localizedDescription)")
        }

        let targetDisplayID: UInt32
        if identifier.lowercased() == "main" {
            targetDisplayID = CGMainDisplayID()
        } else if let parsed = UInt32(identifier) {
            targetDisplayID = parsed
        } else {
            throw ScreenCommanderError.invalidArguments("--display must be 'main' or a numeric display ID.")
        }

        guard let display = content.displays.first(where: { $0.displayID == targetDisplayID }) else {
            throw ScreenCommanderError.invalidArguments("Display '\(identifier)' was not found among shareable displays.")
        }

        return ResolvedDisplay(
            displayID: targetDisplayID,
            displayFramePoints: display.frame,
            scDisplay: display,
            excludedWindows: content.windows.filter { overlayIDs.contains($0.windowID) }
        )
    }
}
