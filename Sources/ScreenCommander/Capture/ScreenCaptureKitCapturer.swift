import CoreGraphics
import Foundation
import ScreenCaptureKit

final class ScreenCaptureKitCapturer: ScreenCapturing {
    func capture(window: SCWindow, includeCursor: Bool) async throws -> CapturedScreenshot {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let windowFrame = window.frame
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

        return CapturedScreenshot(
            image: image,
            displayID: 0,
            displayBoundsPoints: windowFrame,
            pointPixelScale: pointPixelScale
        )
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
