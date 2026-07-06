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
    /// When non-nil, capture this window instead of the full display.
    var windowIdentifier: String?
}

struct ScreenshotResult: Codable, Sendable {
    var imagePath: String
    var metadataPath: String
    var lastMetadataPath: String
    var metadata: ScreenshotMetadata
    /// The captured image, kept in memory for in-process consumers (frame diff)
    /// so they need not re-decode the just-written PNG. Never serialized.
    var image: CGImage?

    init(
        imagePath: String,
        metadataPath: String,
        lastMetadataPath: String,
        metadata: ScreenshotMetadata,
        image: CGImage? = nil
    ) {
        self.imagePath = imagePath
        self.metadataPath = metadataPath
        self.lastMetadataPath = lastMetadataPath
        self.metadata = metadata
        self.image = image
    }

    private enum CodingKeys: String, CodingKey {
        case imagePath
        case metadataPath
        case lastMetadataPath
        case metadata
    }
}

struct ClickRequest {
    var x: Double
    var y: Double
    var coordinateSpace: CoordinateSpace
    var metadataPath: String?
    var button: MouseButtonChoice
    var doubleClick: Bool
    var triple: Bool
    var primeClick: Bool
    var humanLike: Bool
    var modifiers: [String]
}

struct ClickResult: Codable, Sendable {
    var metadataPath: String
    var resolved: ResolvedCoordinate
    var button: MouseButtonChoice
    var doubleClick: Bool
    var triple: Bool
    var primeClick: Bool
    var humanLike: Bool
    var modifiers: [String]
}

struct ScrollRequest {
    var x: Double
    var y: Double
    var coordinateSpace: CoordinateSpace
    var metadataPath: String?
    var dx: Int32
    var dy: Int32
    var unit: ScrollUnit
}

struct ScrollResult: Codable, Sendable {
    var metadataPath: String
    var resolved: ResolvedCoordinate
    var dx: Int32
    var dy: Int32
    var unit: ScrollUnit
}

struct DragRequest {
    var x1: Double
    var y1: Double
    var x2: Double
    var y2: Double
    var coordinateSpace: CoordinateSpace
    var metadataPath: String?
    var button: MouseButtonChoice
    var steps: Int
    var durationMS: Int
}

struct DragResult: Codable, Sendable {
    var metadataPath: String
    var from: ResolvedCoordinate
    var to: ResolvedCoordinate
    var button: MouseButtonChoice
    var steps: Int
    var durationMilliseconds: Int
}

struct MoveRequest {
    var x: Double
    var y: Double
    var coordinateSpace: CoordinateSpace
    var metadataPath: String?
    var dwellMS: Int
}

struct MoveResult: Codable, Sendable {
    var metadataPath: String
    var resolved: ResolvedCoordinate
    var dwellMilliseconds: Int
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

struct ElementsRequest {
    /// `--app` value (pid or app-name match); nil targets the frontmost app.
    var appIdentifier: String?
    var windowID: UInt32?
    var allWindows: Bool
    /// Render the text-only tree view into `ElementsResult.text`.
    var includeText: Bool
    var maxDepth: Int
    var maxElements: Int
    var roles: [String]?
    var visibleOnly: Bool
    var maxValueLength: Int

    init(
        appIdentifier: String? = nil,
        windowID: UInt32? = nil,
        allWindows: Bool = false,
        includeText: Bool = false,
        maxDepth: Int = 40,
        maxElements: Int = 2000,
        roles: [String]? = nil,
        visibleOnly: Bool = false,
        maxValueLength: Int = 200
    ) {
        self.appIdentifier = appIdentifier
        self.windowID = windowID
        self.allWindows = allWindows
        self.includeText = includeText
        self.maxDepth = maxDepth
        self.maxElements = maxElements
        self.roles = roles
        self.visibleOnly = visibleOnly
        self.maxValueLength = maxValueLength
    }
}

struct ElementsResult: Codable, Sendable {
    var app: ResolvedApp
    var windowID: UInt32?
    /// Screenshot metadata used to compute `boundsPixels`, when one was available.
    var metadataPath: String?
    var axPrimed: Bool
    /// True when traversal stopped at `maxElements`.
    var truncated: Bool
    var elements: [AXElementRecord]
    /// Text-only tree rendering; present only in `--text` mode.
    var text: String?
}

struct RectD: Codable, Sendable, Equatable {
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
    /// Set when the screenshot was taken of a specific window instead of a full display.
    var windowID: UInt32?
    /// Bounds of the captured window in global screen points (origin top-left).
    var windowBoundsPoints: RectD?
}

struct ObserveRequest {
    /// `--app` value (pid or app-name match).
    var appIdentifier: String
    /// Event categories to stream (`--events`); defaults to all.
    var kinds: Set<ObservedEventKind>
    /// Stop after this many milliseconds; nil means run until interrupted/matched.
    var timeoutMS: Int?
    /// Optional `--until` predicate; when set, matching ends the stream (exit 0) and a
    /// timeout without a match exits 73.
    var predicate: ObservePredicate?

    init(
        appIdentifier: String,
        kinds: Set<ObservedEventKind> = Set(ObservedEventKind.allCases),
        timeoutMS: Int? = nil,
        predicate: ObservePredicate? = nil
    ) {
        self.appIdentifier = appIdentifier
        self.kinds = kinds
        self.timeoutMS = timeoutMS
        self.predicate = predicate
    }
}

/// How an `observe` session ended. Drives the command's exit code and final output.
enum ObserveOutcome: Equatable, Sendable {
    /// `--until` matched (initial scan or an incoming event). Exit 0; a final
    /// `{ matched: true, element }` line is printed.
    case matched(AXElementRecord?)
    /// Plain observe reached `--timeout-ms`. Exit 0.
    case timedOut
    /// `--until` was unmet within `--timeout-ms`. Exit 73.
    case timedOutUnmet
    /// SIGINT / task cancellation. Exit 0.
    case interrupted
    /// Event source ended on its own (mainly a test-fake path). Exit 0.
    case completed
}

struct WindowsRequest {
    var appIdentifier: String?
}

struct WindowsResult: Codable, Sendable {
    var windows: [WindowInfo]
}

struct FocusRequest {
    var appIdentifier: String
}

struct FocusResult: Codable, Sendable {
    var app: ResolvedApp
    var priorApp: ResolvedApp?
}
