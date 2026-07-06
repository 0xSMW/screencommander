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

        let windowFrame = scWindow.frame

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCommanderError.captureFailed("Could not enumerate displays for window capture: \(error.localizedDescription)")
        }

        guard let display = Self.displayContaining(windowFrame, in: content.displays) else {
            throw ScreenCommanderError.captureFailed("Window \(window.info.windowID) is not on a capturable display.")
        }

        let sourceRect = windowFrame.intersection(display.frame)
        guard !sourceRect.isNull, sourceRect.width > 0, sourceRect.height > 0 else {
            throw ScreenCommanderError.captureFailed("Window \(window.info.windowID) is not on-screen.")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let pointPixelScale = max(1.0, Double(filter.pointPixelScale))

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = max(1, Int((Double(sourceRect.width) * pointPixelScale).rounded()))
        configuration.height = max(1, Int((Double(sourceRect.height) * pointPixelScale).rounded()))
        configuration.showsCursor = includeCursor

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw ScreenCommanderError.captureFailed("ScreenCaptureKit window capture failed: \(error.localizedDescription)")
        }

        // Report the display actually containing the window so metadata's
        // displayID/displayBoundsPoints keep their documented semantics; the
        // captured source rect travels separately as windowBoundsPoints.
        return CapturedScreenshot(
            image: image,
            displayID: display.displayID,
            displayBoundsPoints: display.frame,
            pointPixelScale: pointPixelScale,
            contentBoundsPoints: sourceRect
        )
    }

    /// Finds the ScreenCaptureKit display with the largest intersection against
    /// the window frame. The capture itself uses that display plus a sourceRect;
    /// this avoids the CLI crash observed with desktop-independent window filters.
    private static func displayContaining(_ rect: CGRect, in displays: [SCDisplay]) -> SCDisplay? {
        displays.max { lhs, rhs in
            intersectionArea(lhs.frame, rect) < intersectionArea(rhs.frame, rect)
        }.flatMap { display in
            display.frame.intersects(rect) ? display : nil
        }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else {
            return 0
        }
        return max(0, intersection.width) * max(0, intersection.height)
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
            pointPixelScale: pointPixelScale,
            contentBoundsPoints: nil
        )
    }
}
