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
    var encodedImageData: Data? = nil

    init(
        imagePath: String,
        metadataPath: String,
        lastMetadataPath: String,
        metadata: ScreenshotMetadata,
        image: CGImage? = nil,
        encodedImageData: Data? = nil
    ) {
        self.imagePath = imagePath
        self.metadataPath = metadataPath
        self.lastMetadataPath = lastMetadataPath
        self.metadata = metadata
        self.image = image
        self.encodedImageData = encodedImageData
    }

    private enum CodingKeys: String, CodingKey {
        case imagePath
        case metadataPath
        case lastMetadataPath
        case metadata
    }
}

struct ClickRequest {
    /// Coordinate targeting; nil when targeting an element instead.
    var x: Double?
    var y: Double?
    var coordinateSpace: CoordinateSpace
    var metadataPath: String?
    var button: MouseButtonChoice
    var doubleClick: Bool
    var triple: Bool
    var primeClick: Bool
    var humanLike: Bool
    var modifiers: [String]
    /// Element targeting (`--element`): title/label substring, resolved fresh at click time.
    var element: String? = nil
    /// Element targeting (`--element-id`): dot-joined child-index path from `elements`.
    var elementID: String? = nil
    /// Optional role filter to disambiguate `--element` matches ("button" or "AXButton").
    var role: String? = nil
    /// `--app`: pid or name of the target app; nil = the element's frontmost app, or
    /// for coordinates the screenshot window / window under the point.
    var appIdentifier: String? = nil
    /// `--via`: force one delivery tier (no fallback; strict implied).
    var via: InputDeliveryMethod? = nil
    /// `--no-cursor`: accepted for compatibility; background delivery is the default.
    var noCursor: Bool = false
    /// `--strict`: tier downgrades become errors instead of being recorded.
    var strict: Bool = false
    /// `--verify-target`: hit-test the mapped point and include the element in the result.
    var verifyTarget: Bool = false
    /// Fail coordinate clicks when the metadata is known stale.
    var strictMetadata: Bool = false
    /// `--window-id`: address background events to this window.
    var windowID: UInt32? = nil
    /// `--foreground`: allow activation and HID-tap delivery (tier `global`).
    var foreground: Bool = false
    /// `--session`: the agent session that leases the target; nil uses the process default.
    var session: String? = nil
    /// `--no-agent-cursor` sets false; nil uses the process default.
    var agentCursor: Bool? = nil
}

struct ClickResult: Codable, Sendable {
    /// Present for coordinate clicks only.
    var metadataPath: String?
    /// The mapped coordinate. For element clicks this is the element's center in
    /// global points (space `points`) when delivery needed a point; nil for AX delivery.
    var resolved: ResolvedCoordinate?
    var button: MouseButtonChoice
    var doubleClick: Bool
    var triple: Bool
    var primeClick: Bool
    var humanLike: Bool
    var modifiers: [String]
    /// The tier forced with `--via`, when one was.
    var requestedVia: InputDeliveryMethod? = nil
    /// The tier that actually delivered the input.
    var deliveryMethod: InputDeliveryMethod = .global
    /// The resolved element record, for element clicks.
    var element: AXElementRecord? = nil
    /// The element hit-tested at the mapped point (`--verify-target`).
    var verifiedTarget: AXElementRecord? = nil
    /// Advisory freshness check for coordinate metadata.
    var metadataFreshness: MetadataFreshnessResult? = nil
    /// Frontmost app and cursor before and after delivery.
    var focus: FocusReceipt? = nil
    var verified: ActionVerification = .unknown
    /// Whether the presence process (agent cursor, lease, focus guard, yield) took part.
    var presence: ActionPresence = .disabled
    /// Set when an `ax` press got no confirmation from the app (for example
    /// `cannotComplete`). The press may have run, so no other tier was tried, and
    /// `verified` says what a read-back showed.
    var axError: String? = nil
}

struct ScrollRequest {
    /// Coordinate targeting; nil when targeting an element instead.
    var x: Double?
    var y: Double?
    var coordinateSpace: CoordinateSpace
    var metadataPath: String?
    var dx: Int32
    var dy: Int32
    var unit: ScrollUnit
    /// Element targeting; see `ClickRequest`. Scroll has no AX tier (`pid`/`global` only).
    var element: String? = nil
    var elementID: String? = nil
    var role: String? = nil
    var appIdentifier: String? = nil
    var via: InputDeliveryMethod? = nil
    var noCursor: Bool = false
    var strict: Bool = false
    var strictMetadata: Bool = false
    var windowID: UInt32? = nil
    var foreground: Bool = false
    /// `--session`: the agent session that leases the target; nil uses the process default.
    var session: String? = nil
    /// `--no-agent-cursor` sets false; nil uses the process default.
    var agentCursor: Bool? = nil
    /// `--direction`: page-scroll an element instead of sending `dx`/`dy`.
    var direction: ScrollDirection? = nil
    /// `--pages`: how many pages to scroll with `direction`.
    var pages: Int = 1
}

struct ScrollResult: Codable, Sendable {
    /// Present for coordinate scrolls only.
    var metadataPath: String?
    /// The mapped coordinate (element scrolls report the element's center in points).
    var resolved: ResolvedCoordinate?
    var dx: Int32
    var dy: Int32
    var unit: ScrollUnit
    var requestedVia: InputDeliveryMethod? = nil
    var deliveryMethod: InputDeliveryMethod = .global
    var element: AXElementRecord? = nil
    var metadataFreshness: MetadataFreshnessResult? = nil
    var focus: FocusReceipt? = nil
    var verified: ActionVerification = .unknown
    /// Whether the presence process (agent cursor, lease, focus guard, yield) took part.
    var presence: ActionPresence = .disabled
    /// Page scrolls: the requested direction and page count.
    var direction: ScrollDirection? = nil
    var pages: Int? = nil
    /// Page scrolls delivered via `ax`: the AX route used (`AXScrollDownByPage`,
    /// `AXIncrementPage`, or `AXValue`).
    var axMethod: String? = nil
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
    var strictMetadata: Bool = false
    var appIdentifier: String? = nil
    var windowID: UInt32? = nil
    var foreground: Bool = false
    /// `--session`: the agent session that leases the target; nil uses the process default.
    var session: String? = nil
    /// `--no-agent-cursor` sets false; nil uses the process default.
    var agentCursor: Bool? = nil
}

struct DragResult: Codable, Sendable {
    var metadataPath: String
    var from: ResolvedCoordinate
    var to: ResolvedCoordinate
    var button: MouseButtonChoice
    var steps: Int
    var durationMilliseconds: Int
    var metadataFreshness: MetadataFreshnessResult? = nil
    var deliveryMethod: InputDeliveryMethod = .window
    var focus: FocusReceipt? = nil
    var verified: ActionVerification = .unknown
    /// Whether the presence process (agent cursor, lease, focus guard, yield) took part.
    var presence: ActionPresence = .disabled
}

struct MoveRequest {
    var x: Double
    var y: Double
    var coordinateSpace: CoordinateSpace
    var metadataPath: String?
    var dwellMS: Int
    var strictMetadata: Bool = false
    var appIdentifier: String? = nil
    var windowID: UInt32? = nil
    var foreground: Bool = false
    /// `--session`: the agent session that leases the target; nil uses the process default.
    var session: String? = nil
    /// `--no-agent-cursor` sets false; nil uses the process default.
    var agentCursor: Bool? = nil
}

struct MoveResult: Codable, Sendable {
    var metadataPath: String
    var resolved: ResolvedCoordinate
    var dwellMilliseconds: Int
    var metadataFreshness: MetadataFreshnessResult? = nil
    var deliveryMethod: InputDeliveryMethod = .window
    var focus: FocusReceipt? = nil
    var verified: ActionVerification = .unknown
    /// Whether the presence process (agent cursor, lease, focus guard, yield) took part.
    var presence: ActionPresence = .disabled
}

enum MetadataFreshnessStatus: String, Codable, Sendable {
    case fresh
    case stale
    case unknown
}

struct MetadataFreshnessResult: Codable, Sendable, Equatable {
    var status: MetadataFreshnessStatus
    var scope: String
    var reason: String
}

struct TypeRequest {
    var text: String
    var delayMilliseconds: Int?
    var inputMode: TextInputMode
    /// Element targeting; see `ClickRequest`. Tier `ax` inserts at the element's
    /// caret through `AXSelectedText` (or an `AXValue` splice); the fallbacks focus
    /// the element, keep its selection, and post Unicode key events. Without an
    /// element, tier `ax` uses the target app's focused text element.
    var element: String? = nil
    var elementID: String? = nil
    var role: String? = nil
    /// Keyboard target; nil = the element's app, or the frontmost app.
    var appIdentifier: String? = nil
    var via: InputDeliveryMethod? = nil
    var strict: Bool = false
    var windowID: UInt32? = nil
    var foreground: Bool = false
    /// `--session`: the agent session that leases the target; nil uses the process default.
    var session: String? = nil
    /// `--no-agent-cursor` sets false; nil uses the process default.
    var agentCursor: Bool? = nil
    /// `--replace`: replace the whole value (`AXValue`) instead of inserting at the caret.
    var replace: Bool = false
}

struct TypeResult: Codable, Sendable {
    var textLength: Int
    var delayMilliseconds: Int?
    var inputMode: TypedInputMode
    var requestedVia: InputDeliveryMethod? = nil
    var deliveryMethod: InputDeliveryMethod = .global
    var element: AXElementRecord? = nil
    var focus: FocusReceipt? = nil
    var verified: ActionVerification = .unknown
    /// Whether the presence process (agent cursor, lease, focus guard, yield) took part.
    var presence: ActionPresence = .disabled
    /// True when `--replace` asked for the whole value to be replaced. Absent otherwise.
    var replace: Bool? = nil
    /// The window the keys went to, when that is known: the window that had to be
    /// made key (`--window-id`, or the target element's window), else the app's key
    /// window as accessibility reports it. Absent for `ax` and `global` delivery.
    var keyWindowID: UInt32? = nil
}

/// How key-event delivery enters text. `unicode` (the default) posts one Unicode key
/// event per character and never touches the clipboard. `paste` borrows the clipboard
/// for Command-V and applies only to `global` delivery (`--foreground`).
enum TextInputMode: String, Codable, Sendable {
    case paste
    case unicode
}

/// What actually put the text in, as `type` reports it: Unicode key events, a
/// Command-V paste (`global` delivery with `--mode paste`), or an accessibility
/// write (`ax`), whatever `--mode` asked for.
enum TypedInputMode: String, Codable, Sendable {
    case unicode
    case paste
    case ax
}

struct KeyRequest {
    var chord: String
    /// Keyboard target; nil = the frontmost app.
    var appIdentifier: String? = nil
    var windowID: UInt32? = nil
    var foreground: Bool = false
    /// `--session`: the agent session that leases the target; nil uses the process default.
    var session: String? = nil
    /// `--no-agent-cursor` sets false; nil uses the process default.
    var agentCursor: Bool? = nil
}

struct KeyResult: Codable, Sendable {
    var normalizedChord: String
    var deliveryMethod: InputDeliveryMethod = .window
    /// The menu item a Command shortcut was resolved to and pressed through
    /// Accessibility, as `Menu > Item`. Absent when the chord went out as key events.
    var menuItem: String? = nil
    var focus: FocusReceipt? = nil
    var verified: ActionVerification = .unknown
    /// Whether the presence process (agent cursor, lease, focus guard, yield) took part.
    var presence: ActionPresence = .disabled
    /// The window the keys went to, when that is known: the window that had to be
    /// made key (`--window-id`, or the target element's window), else the app's key
    /// window as accessibility reports it. Absent for `ax` and `global` delivery.
    var keyWindowID: UInt32? = nil
}

struct KeysRequest {
    var steps: [String]
    var appIdentifier: String? = nil
    var windowID: UInt32? = nil
    var foreground: Bool = false
    /// `--session`: the agent session that leases the target; nil uses the process default.
    var session: String? = nil
    /// `--no-agent-cursor` sets false; nil uses the process default.
    var agentCursor: Bool? = nil
}

struct KeysResult: Codable, Sendable {
    var normalizedSteps: [String]
    var deliveryMethod: InputDeliveryMethod = .window
    var focus: FocusReceipt? = nil
    var verified: ActionVerification = .unknown
    /// Whether the presence process (agent cursor, lease, focus guard, yield) took part.
    var presence: ActionPresence = .disabled
    /// The window the keys went to, when that is known: the window that had to be
    /// made key (`--window-id`, or the target element's window), else the app's key
    /// window as accessibility reports it. Absent for `ax` and `global` delivery.
    var keyWindowID: UInt32? = nil
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
    var profile: AXTreeOptions.Profile
    var maxVisited: Int?
    var timeoutMS: Int?
    var snapshot: Bool
    var since: String?

    init(
        appIdentifier: String? = nil,
        windowID: UInt32? = nil,
        allWindows: Bool = false,
        includeText: Bool = false,
        maxDepth: Int = 40,
        maxElements: Int = 2000,
        roles: [String]? = nil,
        visibleOnly: Bool = false,
        maxValueLength: Int = 200,
        profile: AXTreeOptions.Profile = .full,
        maxVisited: Int? = nil,
        timeoutMS: Int? = nil,
        snapshot: Bool = false,
        since: String? = nil
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
        self.profile = profile
        self.maxVisited = maxVisited
        self.timeoutMS = timeoutMS
        self.snapshot = snapshot
        self.since = since
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
    var profile: String? = nil
    var visitedCount: Int? = nil
    var partialReason: String? = nil
    var snapshotId: String? = nil
    var baseSnapshotId: String? = nil
    var removedIds: [String]? = nil
    var resetReason: String? = nil
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

// MARK: - App state, apps, launch, text selection, AX actions, profiles

struct AppStateRequest {
    var appIdentifier: String
    var windowID: UInt32? = nil
    var maxDepth: Int = 40
    var maxElements: Int = 2000
    var includeText: Bool = false
    var format: ImageFormat = .png
    /// Serve mode: return the tree as a delta against this target's previous state.
    var diff: Bool = false
    /// Explicit baseline snapshot for the delta; nil uses the target's last snapshot.
    var since: String? = nil
    /// Serve mode: return the whole tree this time, still keeping it as the new baseline.
    var fullTree: Bool = false
}

struct AppStateResult: Codable, Sendable {
    var app: ResolvedApp
    var windowID: UInt32
    var imagePath: String
    /// The capture's metadata sidecar; coordinate actions map against it (it is also
    /// written to last-screenshot.json).
    var metadataPath: String
    var screenshot: ScreenshotMetadata
    /// Same shape as `elements`. In serve mode it is a delta when `baseSnapshotId` is set.
    var tree: ElementsResult
    /// The captured image, for the MCP image block. Never serialized.
    var image: CGImage? = nil
    var encodedImageData: Data? = nil

    private enum CodingKeys: String, CodingKey {
        case app
        case windowID
        case imagePath
        case metadataPath
        case screenshot
        case tree
    }
}

struct AppsRequest {
    var includeInstalled: Bool = true
    /// Case-insensitive substring over name and bundle ID.
    var filter: String? = nil
}

struct AppsResult: Codable, Sendable {
    var running: [RunningAppEntry]
    var installed: [InstalledAppEntry]?
    var installedTruncated: Bool?
}

struct LaunchRequest {
    /// Name, bundle ID, or path to an `.app`.
    var appIdentifier: String
    var timeoutMS: Int = 10_000
    var session: String? = nil
}

struct LaunchResult: Codable, Sendable {
    var app: ResolvedApp
    var path: String
    /// The app was already running; nothing was launched.
    var alreadyRunning: Bool
    /// The app finished launching (or answered AX) before the timeout.
    var ready: Bool
    var focus: FocusReceipt
    var presence: ActionPresence = .disabled
}

struct SelectTextRequest {
    var element: String? = nil
    var elementID: String? = nil
    var role: String? = nil
    var appIdentifier: String? = nil
    var windowID: UInt32? = nil
    /// Select this UTF-16 range.
    var range: AXTextRange? = nil
    /// Or select the first match of this substring (case-sensitive, then case-insensitive).
    var text: String? = nil
    var session: String? = nil
    var agentCursor: Bool? = nil
}

struct SelectTextResult: Codable, Sendable {
    var element: AXElementRecord
    /// The range that was requested, in UTF-16 code units.
    var range: AXTextRange
    /// `AXSelectedTextRange` read back after the write.
    var selectedRange: AXTextRange?
    var selectedText: String?
    var deliveryMethod: InputDeliveryMethod = .ax
    var focus: FocusReceipt?
    var verified: ActionVerification = .unknown
    var presence: ActionPresence = .disabled
}

struct PerformActionRequest {
    var element: String? = nil
    var elementID: String? = nil
    var role: String? = nil
    var appIdentifier: String? = nil
    var windowID: UInt32? = nil
    /// An AX action name the element lists, e.g. `AXPress` (`Press` also accepted).
    var name: String
    var session: String? = nil
    var agentCursor: Bool? = nil
}

struct PerformActionResult: Codable, Sendable {
    /// The AX action performed, normalized (e.g. `AXShowMenu`).
    var name: String
    var element: AXElementRecord
    var deliveryMethod: InputDeliveryMethod = .ax
    var focus: FocusReceipt?
    var verified: ActionVerification = .unknown
    var presence: ActionPresence = .disabled
}

/// `doctor --app`: the delivery profile for one app, running or installed.
struct AppProfileReport: Codable, Sendable {
    var name: String
    var bundleID: String?
    var pid: pid_t?
    var path: String?
    var running: Bool
    var profile: BackgroundDeliveryProfile
}
