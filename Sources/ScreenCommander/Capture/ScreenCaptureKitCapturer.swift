import AppKit
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
        guard windowFrame.width.isFinite, windowFrame.height.isFinite,
              windowFrame.width >= 1, windowFrame.height >= 1 else {
            throw ScreenCommanderError.captureFailed(
                "Window \(window.info.windowID) reports an unusable frame \(windowFrame)."
            )
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCommanderError.captureFailed("Could not enumerate displays for window capture: \(error.localizedDescription)")
        }

        guard let display = Self.displayContaining(windowFrame, in: content.displays) else {
            throw ScreenCommanderError.captureFailed("Window \(window.info.windowID) is not on a capturable display.")
        }
        guard display.frame.contains(windowFrame) else {
            throw ScreenCommanderError.captureFailed(
                "Window \(window.info.windowID) spans multiple displays or extends outside display \(display.displayID); "
                    + "window capture metadata requires one display scale."
            )
        }

        // Desktop-independent filter: captures the window's own contents regardless
        // of occlusion or z-order (a display filter + sourceRect crops the screen
        // region instead, bleeding whatever is on top into the image). For window
        // filters, `contentRect` can be infinite and `pointPixelScale` 0, so never
        // size the capture from the filter — use the window frame, and take the
        // scale from the containing display when the window filter's is unusable.
        // Requires the window-server connection established by
        // WindowServerConnection.ensureInitialized() — see that type for why this
        // cannot happen here (the CLI's main thread is blocked in AsyncBridge by
        // the time this code runs).
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        var pointPixelScale = Double(filter.pointPixelScale)
        if !pointPixelScale.isFinite || pointPixelScale < 1 {
            pointPixelScale = Double(SCContentFilter(display: display, excludingWindows: []).pointPixelScale)
        }
        if !pointPixelScale.isFinite || pointPixelScale < 1 {
            throw ScreenCommanderError.captureFailed(
                "Window \(window.info.windowID) reports an unusable pointPixelScale."
            )
        }

        let widthPixels = (Double(windowFrame.width) * pointPixelScale).rounded()
        let heightPixels = (Double(windowFrame.height) * pointPixelScale).rounded()
        guard widthPixels.isFinite, heightPixels.isFinite,
              (1...65_536).contains(widthPixels), (1...65_536).contains(heightPixels) else {
            throw ScreenCommanderError.captureFailed(
                "Window \(window.info.windowID) computes an unusable capture size (\(widthPixels)x\(heightPixels))."
            )
        }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(widthPixels)
        configuration.height = Int(heightPixels)
        configuration.showsCursor = includeCursor

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw ScreenCommanderError.captureFailed("ScreenCaptureKit window capture failed: \(error.localizedDescription)")
        }

        // Report the display actually containing the window so metadata's
        // displayID/displayBoundsPoints keep their documented semantics; the
        // window's full frame travels separately as windowBoundsPoints.
        return CapturedScreenshot(
            image: image,
            displayID: display.displayID,
            displayBoundsPoints: display.frame,
            pointPixelScale: pointPixelScale,
            contentBoundsPoints: windowFrame
        )
    }

    /// Finds the ScreenCaptureKit display with the largest intersection against
    /// the window frame, for metadata and as the pixel-scale fallback.
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
        let pointPixelScale = Double(filter.pointPixelScale)
        guard pointPixelScale.isFinite, pointPixelScale >= 1 else {
            throw ScreenCommanderError.captureFailed("Display \(display.displayID) reports an unusable pointPixelScale.")
        }

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
