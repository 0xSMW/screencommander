import AppKit
import CoreGraphics
import Foundation

final class ScreenCommanderEngine {
    private let permissions: PermissionChecking
    private let displays: DisplayResolving
    private let capturer: ScreenCapturing
    private let imageWriter: ImageWriting
    private let metadataStore: SnapshotMetadataStoring
    private let coordinateMapper: CoordinateMapper
    private let mouseController: MouseControlling
    private let keyboardController: KeyboardControlling
    private let retention: CaptureRetentionManaging
    private let fileManager: FileManager
    private let statePaths: StatePaths
    private let now: () -> Date
    let targetResolver: TargetResolving

    init(
        permissions: PermissionChecking,
        displays: DisplayResolving,
        capturer: ScreenCapturing,
        imageWriter: ImageWriting,
        metadataStore: SnapshotMetadataStoring,
        coordinateMapper: CoordinateMapper,
        mouseController: MouseControlling,
        keyboardController: KeyboardControlling,
        retention: CaptureRetentionManaging,
        statePaths: StatePaths,
        targetResolver: TargetResolving = Targets(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.permissions = permissions
        self.displays = displays
        self.capturer = capturer
        self.imageWriter = imageWriter
        self.metadataStore = metadataStore
        self.coordinateMapper = coordinateMapper
        self.mouseController = mouseController
        self.keyboardController = keyboardController
        self.retention = retention
        self.statePaths = statePaths
        self.targetResolver = targetResolver
        self.fileManager = fileManager
        self.now = now
    }

    static func live(fileManager: FileManager = .default) -> ScreenCommanderEngine {
        let statePaths = StatePaths(fileManager: fileManager)
        let metadataStore = SnapshotMetadataStore(
            fileManager: fileManager,
            lastMetadataURL: statePaths.lastMetadataURL
        )

        return ScreenCommanderEngine(
            permissions: Permissions(),
            displays: Displays(),
            capturer: ScreenCaptureKitCapturer(),
            imageWriter: ImageWriter(fileManager: fileManager),
            metadataStore: metadataStore,
            coordinateMapper: CoordinateMapper(),
            mouseController: MouseController(),
            keyboardController: KeyboardController(),
            retention: CaptureRetentionManager(fileManager: fileManager),
            statePaths: statePaths,
            targetResolver: Targets(),
            fileManager: fileManager
        )
    }

    func screenshot(_ request: ScreenshotRequest) async throws -> ScreenshotResult {
        _ = try? retention.pruneCaptures(
            in: statePaths.capturesDirectoryURL,
            olderThan: 24 * 60 * 60,
            now: now()
        )

        try permissions.ensureScreenRecordingAccess(prompt: true)

        let imageURL = resolvedImageURL(explicitPath: request.outputPath, format: request.format)
        let metadataURL = resolvedMetadataURL(explicitPath: request.metadataPath, imageURL: imageURL)
        let lastMetadataURL = request.updateLastMetadata ? metadataStore.defaultLastMetadataURL : metadataURL

        // Window capture path
        if let windowIdentifier = request.windowIdentifier {
            let (scWindow, windowInfo) = try await targetResolver.resolveWindow(identifier: windowIdentifier, app: nil)
            let captured = try await capturer.capture(window: scWindow, includeCursor: request.includeCursor)
            let pixelSize = try imageWriter.write(image: captured.image, format: request.format, to: imageURL)

            let metadata = ScreenshotMetadata(
                capturedAtISO8601: Self.iso8601Formatter.string(from: now()),
                displayID: captured.displayID,
                displayBoundsPoints: RectD(captured.displayBoundsPoints),
                imageSizePixels: pixelSize,
                pointPixelScale: captured.pointPixelScale,
                imagePath: imageURL.path,
                windowID: windowInfo.windowID,
                windowBoundsPoints: windowInfo.boundsPoints
            )

            try metadataStore.save(metadata: metadata, at: metadataURL, updateLastAt: lastMetadataURL)

            return ScreenshotResult(
                imagePath: imageURL.path,
                metadataPath: metadataURL.path,
                lastMetadataPath: lastMetadataURL.path,
                metadata: metadata
            )
        }

        // Display capture path (existing behavior)
        let display = try await displays.resolveDisplay(identifier: request.displayIdentifier)
        let captured = try await capturer.capture(display: display, includeCursor: request.includeCursor)
        let pixelSize = try imageWriter.write(image: captured.image, format: request.format, to: imageURL)

        let metadata = ScreenshotMetadata(
            capturedAtISO8601: Self.iso8601Formatter.string(from: now()),
            displayID: captured.displayID,
            displayBoundsPoints: RectD(captured.displayBoundsPoints),
            imageSizePixels: pixelSize,
            pointPixelScale: captured.pointPixelScale,
            imagePath: imageURL.path
        )

        try metadataStore.save(metadata: metadata, at: metadataURL, updateLastAt: lastMetadataURL)

        return ScreenshotResult(
            imagePath: imageURL.path,
            metadataPath: metadataURL.path,
            lastMetadataPath: lastMetadataURL.path,
            metadata: metadata
        )
    }

    func windows(_ request: WindowsRequest) async throws -> WindowsResult {
        try permissions.ensureScreenRecordingAccess(prompt: false)
        let app: ResolvedApp?
        if let id = request.appIdentifier {
            app = try await targetResolver.resolveApp(identifier: id)
        } else {
            app = nil
        }
        let list = try await targetResolver.listWindows(app: app)
        return WindowsResult(windows: list)
    }

    func focus(_ request: FocusRequest) async throws -> FocusResult {
        let app = try await targetResolver.resolveApp(identifier: request.appIdentifier)

        let priorApp: ResolvedApp?
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            priorApp = ResolvedApp(
                pid: frontmost.processIdentifier,
                name: frontmost.localizedName ?? "(unknown)",
                bundleID: frontmost.bundleIdentifier
            )
        } else {
            priorApp = nil
        }

        guard let runningApp = NSRunningApplication(processIdentifier: app.pid) else {
            throw ScreenCommanderError.appNotFound("App with PID \(app.pid) is no longer running.")
        }
        runningApp.activate(options: [.activateIgnoringOtherApps])

        return FocusResult(app: app, priorApp: priorApp)
    }

    func click(_ request: ClickRequest) throws -> ClickResult {
        try permissions.ensureAccessibilityAccess(prompt: true)

        let metadataURL = resolvedURL(for: request.metadataPath ?? metadataStore.defaultLastMetadataURL.path)
        let metadata = try metadataStore.load(from: metadataURL)

        let resolved = try coordinateMapper.map(
            x: request.x,
            y: request.y,
            space: request.coordinateSpace,
            metadata: metadata
        )

        try mouseController.click(
            at: CGPoint(x: resolved.globalX, y: resolved.globalY),
            button: request.button,
            doubleClick: request.doubleClick,
            primeClick: request.primeClick,
            humanLike: request.humanLike
        )

        return ClickResult(
            metadataPath: metadataURL.path,
            resolved: resolved,
            button: request.button,
            doubleClick: request.doubleClick,
            primeClick: request.primeClick,
            humanLike: request.humanLike
        )
    }

    func type(_ request: TypeRequest) throws -> TypeResult {
        if let delay = request.delayMilliseconds, delay < 0 {
            throw ScreenCommanderError.invalidArguments("--delay-ms must be greater than or equal to zero.")
        }

        try permissions.ensureAccessibilityAccess(prompt: true)
        switch request.inputMode {
        case .paste:
            try keyboardController.typeByPasting(text: request.text)
        case .unicode:
            try keyboardController.type(text: request.text, delayMilliseconds: request.delayMilliseconds)
        }

        return TypeResult(
            textLength: request.text.count,
            delayMilliseconds: request.delayMilliseconds,
            inputMode: request.inputMode
        )
    }

    func key(_ request: KeyRequest) throws -> KeyResult {
        let chord = try KeyCodes.parseChord(request.chord)

        try permissions.ensureAccessibilityAccess(prompt: true)
        try keyboardController.press(chord: chord)

        return KeyResult(normalizedChord: chord.normalized)
    }

    func keys(_ request: KeysRequest) throws -> KeysResult {
        let sequence = try KeySequenceParser.parse(request.steps)

        try permissions.ensureAccessibilityAccess(prompt: true)
        try keyboardController.run(sequence: sequence)

        return KeysResult(normalizedSteps: sequence.steps.map { $0.normalized })
    }

    func cleanup(_ request: CleanupRequest) throws -> CleanupResult {
        let olderThanHours = request.olderThanHours ?? 24
        guard olderThanHours >= 0 else {
            throw ScreenCommanderError.invalidArguments("--older-than-hours must be non-negative.")
        }

        return try retention.pruneCaptures(
            in: statePaths.capturesDirectoryURL,
            olderThan: TimeInterval(olderThanHours * 60 * 60),
            now: now()
        )
    }

    private func resolvedImageURL(explicitPath: String?, format: ImageFormat) -> URL {
        if let explicitPath {
            return resolvedURL(for: explicitPath)
        }

        let timestamp = Self.filenameTimestampFormatter.string(from: now())
        let filename = "Screenshot-\(timestamp).\(format.fileExtension)"
        return statePaths.capturesDirectoryURL.appendingPathComponent(filename)
    }

    private func resolvedMetadataURL(explicitPath: String?, imageURL: URL) -> URL {
        if let explicitPath {
            return resolvedURL(for: explicitPath)
        }

        return imageURL.deletingPathExtension().appendingPathExtension("json")
    }

    private func resolvedURL(for path: String) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }

        return URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(expanded)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let filenameTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()
}
