import CoreGraphics
import Foundation

struct CapturedScreenshot {
    let image: CGImage
    let displayID: UInt32
    let displayBoundsPoints: CGRect
    let pointPixelScale: Double
}

protocol ScreenCapturing {
    func capture(display: ResolvedDisplay, includeCursor: Bool) async throws -> CapturedScreenshot
}
