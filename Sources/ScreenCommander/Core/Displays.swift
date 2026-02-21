import CoreGraphics
import Foundation
import ScreenCaptureKit

struct ResolvedDisplay {
    let displayID: UInt32
    let displayFramePoints: CGRect
    let scDisplay: SCDisplay
}

protocol DisplayResolving {
    func resolveDisplay(identifier: String) async throws -> ResolvedDisplay
}

final class Displays: DisplayResolving {
    func resolveDisplay(identifier: String) async throws -> ResolvedDisplay {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
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
            scDisplay: display
        )
    }
}
