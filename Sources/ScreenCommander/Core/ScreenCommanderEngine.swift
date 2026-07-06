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
    private let accessibilityReader: AccessibilityReading
    private let targets: TargetResolving
    private let observationSource: ObservationSource
    private let frontmostApp: () -> ResolvedApp?
    private let activateApp: (ResolvedApp) throws -> Void
    private let fileManager: FileManager
    private let statePaths: StatePaths
    private let now: () -> Date

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
        accessibilityReader: AccessibilityReading = AXReader(),
        targets: TargetResolving = Targets(),
        observationSource: ObservationSource = AXObserverSource(),
        frontmostApp: @escaping () -> ResolvedApp? = FrontmostApp.current,
        activateApp: @escaping (ResolvedApp) throws -> Void = AppActivator.activate,
        statePaths: StatePaths,
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
        self.accessibilityReader = accessibilityReader
        self.targets = targets
        self.observationSource = observationSource
        self.frontmostApp = frontmostApp
        self.activateApp = activateApp
        self.statePaths = statePaths
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
            accessibilityReader: AXReader(),
            targets: Targets(),
            observationSource: AXObserverSource(),
            frontmostApp: FrontmostApp.current,
            activateApp: AppActivator.activate,
            statePaths: statePaths,
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
            let window = try await targets.resolveWindow(identifier: windowIdentifier, app: nil)
            let captured = try await capturer.capture(window: window, includeCursor: request.includeCursor)
            let pixelSize = try imageWriter.write(image: captured.image, format: request.format, to: imageURL)

            let metadata = ScreenshotMetadata(
                capturedAtISO8601: Self.iso8601Formatter.string(from: now()),
                displayID: captured.displayID,
                displayBoundsPoints: RectD(captured.displayBoundsPoints),
                imageSizePixels: pixelSize,
                pointPixelScale: captured.pointPixelScale,
                imagePath: imageURL.path,
                windowID: window.info.windowID,
                windowBoundsPoints: window.info.boundsPoints
            )

            try metadataStore.save(metadata: metadata, at: metadataURL, updateLastAt: lastMetadataURL)

            return ScreenshotResult(
                imagePath: imageURL.path,
                metadataPath: metadataURL.path,
                lastMetadataPath: lastMetadataURL.path,
                metadata: metadata,
                image: captured.image
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
            metadata: metadata,
            image: captured.image
        )
    }

    func windows(_ request: WindowsRequest) async throws -> WindowsResult {
        try permissions.ensureScreenRecordingAccess(prompt: false)
        let app: ResolvedApp?
        if let id = request.appIdentifier {
            app = try await targets.resolveApp(identifier: id)
        } else {
            app = nil
        }
        let list = try await targets.listWindows(app: app)
        return WindowsResult(windows: list)
    }

    func focus(_ request: FocusRequest) async throws -> FocusResult {
        let app = try await targets.resolveApp(identifier: request.appIdentifier)
        let priorApp = frontmostApp()
        try activateApp(app)
        return FocusResult(app: app, priorApp: priorApp)
    }

    func click(_ request: ClickRequest) throws -> ClickResult {
        if request.doubleClick && request.triple {
            throw ScreenCommanderError.invalidArguments("--double and --triple are mutually exclusive.")
        }

        let modifiers = try MouseModifiers.normalized(request.modifiers)

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
            tripleClick: request.triple,
            primeClick: request.primeClick,
            humanLike: request.humanLike,
            modifiers: modifiers
        )

        return ClickResult(
            metadataPath: metadataURL.path,
            resolved: resolved,
            button: request.button,
            doubleClick: request.doubleClick,
            triple: request.triple,
            primeClick: request.primeClick,
            humanLike: request.humanLike,
            modifiers: modifiers
        )
    }

    func scroll(_ request: ScrollRequest) throws -> ScrollResult {
        if request.dx == 0 && request.dy == 0 {
            throw ScreenCommanderError.invalidArguments("At least one of --dx or --dy must be nonzero.")
        }

        try permissions.ensureAccessibilityAccess(prompt: true)

        let metadataURL = resolvedURL(for: request.metadataPath ?? metadataStore.defaultLastMetadataURL.path)
        let metadata = try metadataStore.load(from: metadataURL)
        let resolved = try coordinateMapper.map(
            x: request.x,
            y: request.y,
            space: request.coordinateSpace,
            metadata: metadata
        )

        try mouseController.scroll(
            at: CGPoint(x: resolved.globalX, y: resolved.globalY),
            dx: request.dx,
            dy: request.dy,
            unit: request.unit
        )

        return ScrollResult(
            metadataPath: metadataURL.path,
            resolved: resolved,
            dx: request.dx,
            dy: request.dy,
            unit: request.unit
        )
    }

    func drag(_ request: DragRequest) throws -> DragResult {
        if request.steps < 1 {
            throw ScreenCommanderError.invalidArguments("--steps must be greater than zero.")
        }
        if request.durationMS < 0 {
            throw ScreenCommanderError.invalidArguments("--duration-ms must be greater than or equal to zero.")
        }

        try permissions.ensureAccessibilityAccess(prompt: true)

        let metadataURL = resolvedURL(for: request.metadataPath ?? metadataStore.defaultLastMetadataURL.path)
        let metadata = try metadataStore.load(from: metadataURL)
        let from = try coordinateMapper.map(
            x: request.x1,
            y: request.y1,
            space: request.coordinateSpace,
            metadata: metadata
        )
        let to = try coordinateMapper.map(
            x: request.x2,
            y: request.y2,
            space: request.coordinateSpace,
            metadata: metadata
        )

        try mouseController.drag(
            from: CGPoint(x: from.globalX, y: from.globalY),
            to: CGPoint(x: to.globalX, y: to.globalY),
            button: request.button,
            steps: request.steps,
            durationMS: request.durationMS
        )

        return DragResult(
            metadataPath: metadataURL.path,
            from: from,
            to: to,
            button: request.button,
            steps: request.steps,
            durationMilliseconds: request.durationMS
        )
    }

    func move(_ request: MoveRequest) throws -> MoveResult {
        if request.dwellMS < 0 {
            throw ScreenCommanderError.invalidArguments("--dwell-ms must be greater than or equal to zero.")
        }

        try permissions.ensureAccessibilityAccess(prompt: true)

        let metadataURL = resolvedURL(for: request.metadataPath ?? metadataStore.defaultLastMetadataURL.path)
        let metadata = try metadataStore.load(from: metadataURL)
        let resolved = try coordinateMapper.map(
            x: request.x,
            y: request.y,
            space: request.coordinateSpace,
            metadata: metadata
        )

        try mouseController.move(to: CGPoint(x: resolved.globalX, y: resolved.globalY))
        SleepTimer.sleep(milliseconds: request.dwellMS)

        return MoveResult(
            metadataPath: metadataURL.path,
            resolved: resolved,
            dwellMilliseconds: request.dwellMS
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

    func elements(_ request: ElementsRequest) async throws -> ElementsResult {
        guard request.maxDepth >= 1 else {
            throw ScreenCommanderError.invalidArguments("--max-depth must be at least 1.")
        }
        guard request.maxElements >= 1 else {
            throw ScreenCommanderError.invalidArguments("--max-elements must be at least 1.")
        }
        guard request.maxValueLength >= 0 else {
            throw ScreenCommanderError.invalidArguments("--max-value-length must be non-negative.")
        }
        guard request.windowID == nil || !request.allWindows else {
            throw ScreenCommanderError.invalidArguments("--window-id and --all-windows are mutually exclusive.")
        }

        try permissions.ensureAccessibilityAccess(prompt: true)

        let app: ResolvedApp
        if let identifier = request.appIdentifier {
            app = try await targets.resolveApp(identifier: identifier)
        } else if let frontmost = frontmostApp() {
            app = frontmost
        } else {
            throw ScreenCommanderError.invalidArguments(
                "Could not determine the frontmost application; pass --app <name|pid>."
            )
        }

        let options = AXTreeOptions(
            windowID: request.windowID,
            allWindows: request.allWindows,
            maxDepth: request.maxDepth,
            maxElements: request.maxElements,
            roles: request.roles,
            visibleOnly: request.visibleOnly,
            maxValueLength: request.maxValueLength
        )
        let tree = try accessibilityReader.tree(app: app, options: options)

        // Pixel bounds are derived from the last screenshot's metadata when present;
        // no metadata (or elements outside its bounds) simply means no boundsPixels.
        var elements = tree.elements
        var metadataPath: String?
        let lastMetadataURL = metadataStore.defaultLastMetadataURL
        if let metadata = try? metadataStore.load(from: lastMetadataURL) {
            metadataPath = lastMetadataURL.path
            elements = elements.map { record in
                var record = record
                record.boundsPixels = record.boundsPoints.flatMap {
                    AXBoundsMapper.boundsPixels(for: $0, metadata: metadata)
                }
                return record
            }
        }

        return ElementsResult(
            app: app,
            windowID: request.windowID,
            metadataPath: metadataPath,
            axPrimed: tree.axPrimed,
            truncated: tree.truncated,
            elements: elements,
            text: request.includeText ? AXTextRenderer.render(elements) : nil
        )
    }

    /// Streams UI-change events for an app until interrupted, timed out, or `--until`
    /// matched. `emit` is called once per event (the command prints NDJSON); the return
    /// value tells the command how to exit.
    ///
    /// Structured around an `AsyncStream<ObservedEvent>` so WP8's MCP server can hold
    /// observers warm and answer "what changed since last call" without re-registering.
    func observe(
        _ request: ObserveRequest,
        emit: @escaping @Sendable (ObservedEvent) -> Void
    ) async throws -> ObserveOutcome {
        guard !request.kinds.isEmpty else {
            throw ScreenCommanderError.invalidArguments("--events selected no event kinds.")
        }
        if let timeout = request.timeoutMS, timeout < 0 {
            throw ScreenCommanderError.invalidArguments("--timeout-ms must be non-negative.")
        }

        try permissions.ensureAccessibilityAccess(prompt: true)

        let app = try await targets.resolveApp(identifier: request.appIdentifier)

        // Initial scan: already-true `--until` conditions return immediately without
        // waiting for a live event.
        if let predicate = request.predicate {
            let options = AXTreeOptions()
            if let tree = try? accessibilityReader.tree(app: app, options: options),
               let match = predicate.firstMatch(in: tree.elements) {
                return .matched(match)
            }
        }

        let kinds = request.kinds
        let predicate = request.predicate
        let stream = observationSource.events(app: app, kinds: kinds)

        return await withTaskGroup(of: ObserveOutcome?.self) { group in
            group.addTask {
                for await event in stream {
                    // Defensive re-filter: the production source only registers the
                    // requested kinds, but a fake source may yield anything.
                    guard kinds.contains(event.kind) else { continue }
                    emit(event)
                    if let predicate, let element = event.element, predicate.matches(element) {
                        return .matched(element)
                    }
                }
                return .completed
            }

            if let timeout = request.timeoutMS {
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000)
                    if Task.isCancelled { return nil }
                    return predicate == nil ? .timedOut : .timedOutUnmet
                }
            }

            var outcome: ObserveOutcome = .completed
            for await result in group {
                if let result {
                    outcome = result
                    break
                }
            }
            group.cancelAll()
            return outcome
        }
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
