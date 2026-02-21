import CoreGraphics
import Foundation

struct RectD: Codable, Sendable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    init(_ rect: CGRect) {
        self.init(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            w: Double(rect.width),
            h: Double(rect.height)
        )
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }
}

struct SizeD: Codable, Sendable {
    var w: Double
    var h: Double

    init(w: Double, h: Double) {
        self.w = w
        self.h = h
    }
}

struct ScreenshotMetadata: Codable, Sendable {
    var capturedAtISO8601: String
    var displayID: UInt32
    var displayBoundsPoints: RectD
    var imageSizePixels: SizeD
    var pointPixelScale: Double
    var imagePath: String
}
