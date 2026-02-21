import CoreGraphics
import Foundation

struct PointD: Codable, Sendable {
    var x: Double
    var y: Double
}

struct ScreenshotRequest {
    var displayIdentifier: String
    var outputPath: String?
    var format: ImageFormat
    var metadataPath: String?
    var includeCursor: Bool
    var updateLastMetadata: Bool
}

struct ScreenshotResult: Codable, Sendable {
    var imagePath: String
    var metadataPath: String
    var lastMetadataPath: String
    var metadata: ScreenshotMetadata
}

struct ClickRequest {
    var x: Double
    var y: Double
    var coordinateSpace: CoordinateSpace
    var metadataPath: String?
    var button: MouseButtonChoice
    var doubleClick: Bool
    var primeClick: Bool
    var humanLike: Bool
}

struct ClickResult: Codable, Sendable {
    var metadataPath: String
    var resolved: ResolvedCoordinate
    var button: MouseButtonChoice
    var doubleClick: Bool
    var primeClick: Bool
    var humanLike: Bool
}

struct TypeRequest {
    var text: String
    var delayMilliseconds: Int?
    var inputMode: TextInputMode
}

struct TypeResult: Codable, Sendable {
    var textLength: Int
    var delayMilliseconds: Int?
    var inputMode: TextInputMode
}

enum TextInputMode: String, Codable, Sendable {
    case paste
    case unicode
}

struct KeyRequest {
    var chord: String
}

struct KeyResult: Codable, Sendable {
    var normalizedChord: String
}

struct KeysRequest {
    var steps: [String]
}

struct KeysResult: Codable, Sendable {
    var normalizedSteps: [String]
}

struct CleanupRequest {
    var olderThanHours: Int?
}

struct CleanupResult: Codable, Sendable {
    var deletedCount: Int
    var deletedBytesApprox: Int64
}

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
