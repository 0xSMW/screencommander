import CoreGraphics
import Foundation
import ScreenCaptureKit

struct CapturedScreenshot {
    let image: CGImage
    let displayID: UInt32
    let displayBoundsPoints: CGRect
    let pointPixelScale: Double
    /// Present when the image captures a sub-rectangle of the display, such as a
    /// window source rect. Coordinate mapping should use this as the image origin.
    let contentBoundsPoints: CGRect?

    init(
        image: CGImage,
        displayID: UInt32,
        displayBoundsPoints: CGRect,
        pointPixelScale: Double,
        contentBoundsPoints: CGRect? = nil
    ) {
        self.image = image
        self.displayID = displayID
        self.displayBoundsPoints = displayBoundsPoints
        self.pointPixelScale = pointPixelScale
        self.contentBoundsPoints = contentBoundsPoints
    }
}

protocol ScreenCapturing {
    func capture(display: ResolvedDisplay, includeCursor: Bool) async throws -> CapturedScreenshot
    func capture(window: ResolvedWindow, includeCursor: Bool) async throws -> CapturedScreenshot
}
