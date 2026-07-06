import CoreGraphics
import Foundation
import ScreenCaptureKit

final class ScreenCaptureKitCapturer: ScreenCapturing {
    func capture(window: ResolvedWindow, includeCursor: Bool) async throws -> CapturedScreenshot {
        guard let scWindow = window.scWindow else {
            throw ScreenCommanderError.captureFailed(
                "Window \(window.info.windowID) has no ScreenCaptureKit handle to capture."
            )
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let windowFrame = scWindow.frame
        let pointPixelScale = max(1.0, Double(filter.pointPixelScale))

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((Double(windowFrame.width) * pointPixelScale).rounded()))
        configuration.height = max(1, Int((Double(windowFrame.height) * pointPixelScale).rounded()))
        configuration.showsCursor = includeCursor

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw ScreenCommanderError.captureFailed("ScreenCaptureKit window capture failed: \(error.localizedDescription)")
        }

        // Report the display actually containing the window so metadata's
        // displayID/displayBoundsPoints keep their documented semantics; the
        // window frame travels separately as windowBoundsPoints.
        let (displayID, displayBounds) = Self.displayContaining(windowFrame)

        return CapturedScreenshot(
            image: image,
            displayID: displayID,
            displayBoundsPoints: displayBounds,
            pointPixelScale: pointPixelScale
        )
    }

    /// Finds the display whose bounds intersect the given global-point rect,
    /// falling back to the main display when none does (e.g. off-screen windows).
    private static func displayContaining(_ rect: CGRect) -> (UInt32, CGRect) {
        var displayID: CGDirectDisplayID = 0
        var matchCount: UInt32 = 0
        let error = CGGetDisplaysWithRect(rect, 1, &displayID, &matchCount)
        if error != .success || matchCount == 0 {
            displayID = CGMainDisplayID()
        }
        return (displayID, CGDisplayBounds(displayID))
    }

    func capture(display: ResolvedDisplay, includeCursor: Bool) async throws -> CapturedScreenshot {
        let filter = SCContentFilter(display: display.scDisplay, excludingWindows: [])
        let contentRect = filter.contentRect
        let pointPixelScale = max(1.0, Double(filter.pointPixelScale))

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((Double(contentRect.width) * pointPixelScale).rounded()))
        configuration.height = max(1, Int((Double(contentRect.height) * pointPixelScale).rounded()))
        configuration.showsCursor = includeCursor

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw ScreenCommanderError.captureFailed("ScreenCaptureKit reported an error: \(error.localizedDescription)")
        }

        let displayBoundsPoints = CGRect(
            x: display.displayFramePoints.origin.x,
            y: display.displayFramePoints.origin.y,
            width: contentRect.width,
            height: contentRect.height
        )

        return CapturedScreenshot(
            image: image,
            displayID: display.displayID,
            displayBoundsPoints: displayBoundsPoints,
            pointPixelScale: pointPixelScale
        )
    }
}
