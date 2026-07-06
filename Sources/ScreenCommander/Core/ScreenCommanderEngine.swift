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
    private let axActions: AXActionPerforming
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
        axActions: AXActionPerforming = AXActions(),
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
        self.axActions = axActions
        self.targets = targets
        self.observationSource = observationSource
        self.frontmostApp = frontmostApp
        self.activateApp = activateApp
        self.statePaths = statePaths
        self.fileManager = fileManager
        self.now = now
    }

    /// `shareableContentTTL` caches the ~100–300 ms SCShareableContent enumeration for
    /// that many seconds. 0 (the CLI default) fetches fresh on every call; serve mode
    /// passes a short TTL so a warm server doesn't re-enumerate per tool call.
    static func live(
        fileManager: FileManager = .default,
        shareableContentTTL: TimeInterval = 0
    ) -> ScreenCommanderEngine {
        let statePaths = StatePaths(fileManager: fileManager)
        let metadataStore = SnapshotMetadataStore(
            fileManager: fileManager,
            lastMetadataURL: statePaths.lastMetadataURL
        )
        let contentProvider = ShareableContentProvider(ttl: shareableContentTTL)

        return ScreenCommanderEngine(
            permissions: Permissions(),
            displays: Displays(contentProvider: contentProvider),
            capturer: ScreenCaptureKitCapturer(),
            imageWriter: ImageWriter(fileManager: fileManager),
            metadataStore: metadataStore,
            coordinateMapper: CoordinateMapper(),
            mouseController: MouseController(),
            keyboardController: KeyboardController(),
            retention: CaptureRetentionManager(fileManager: fileManager),
            accessibilityReader: AXReader(),
            axActions: AXActions(),
            targets: Targets(contentProvider: contentProvider),
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
                windowBoundsPoints: captured.contentBoundsPoints.map(RectD.init) ?? window.info.boundsPoints
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
        let list = try await targets.listWindows(app: app).filter(\.isOnScreen)
        return WindowsResult(windows: list)
    }

    func focus(_ request: FocusRequest) async throws -> FocusResult {
        let app = try await targets.resolveApp(identifier: request.appIdentifier)
        let priorApp = frontmostApp()
        try activateApp(app)
        return FocusResult(app: app, priorApp: priorApp)
    }

    func click(_ request: ClickRequest) async throws -> ClickResult {
        if request.doubleClick && request.triple {
            throw ScreenCommanderError.invalidArguments("--double and --triple are mutually exclusive.")
        }

        let modifiers = try MouseModifiers.normalized(request.modifiers)

        if request.element != nil || request.elementID != nil {
            return try await elementClick(request, modifiers: modifiers)
        }
        return try await coordinateClick(request, modifiers: modifiers)
    }

    private func coordinateClick(_ request: ClickRequest, modifiers: [String]) async throws -> ClickResult {
        guard let x = request.x, let y = request.y else {
            throw ScreenCommanderError.invalidArguments("Provide x and y coordinates, or target an element with --element/--element-id.")
        }

        try permissions.ensureAccessibilityAccess(prompt: true)
        let destination = try await coordinateDestination(
            via: request.via,
            noCursor: request.noCursor,
            appIdentifier: request.appIdentifier
        )

        let metadataURL = resolvedURL(for: request.metadataPath ?? metadataStore.defaultLastMetadataURL.path)
        let metadata = try metadataStore.load(from: metadataURL)

        let resolved = try coordinateMapper.map(
            x: x,
            y: y,
            space: request.coordinateSpace,
            metadata: metadata
        )
        let point = CGPoint(x: resolved.globalX, y: resolved.globalY)

        // Pre-click validation: what does the AX hit test say lives at this point?
        var verifiedTarget: AXElementRecord?
        if request.verifyTarget {
            verifiedTarget = try accessibilityReader.elementAt(globalPoint: point)
        }

        try mouseController.click(
            at: point,
            button: request.button,
            doubleClick: request.doubleClick,
            tripleClick: request.triple,
            primeClick: request.primeClick,
            humanLike: request.humanLike,
            modifiers: modifiers,
            destination: destination
        )

        return ClickResult(
            metadataPath: metadataURL.path,
            resolved: resolved,
            button: request.button,
            doubleClick: request.doubleClick,
            triple: request.triple,
            primeClick: request.primeClick,
            humanLike: request.humanLike,
            modifiers: modifiers,
            requestedVia: request.via,
            deliveryMethod: deliveryMethod(for: destination),
            verifiedTarget: verifiedTarget
        )
    }

    private func elementClick(_ request: ClickRequest, modifiers: [String]) async throws -> ClickResult {
        guard request.x == nil, request.y == nil else {
            throw ScreenCommanderError.invalidArguments("Pass either coordinates or --element/--element-id, not both.")
        }
        guard !request.verifyTarget else {
            throw ScreenCommanderError.invalidArguments("--verify-target applies to coordinate clicks only.")
        }

        try permissions.ensureAccessibilityAccess(prompt: true)
        let target = try await resolveElementTarget(
            element: request.element,
            elementID: request.elementID,
            role: request.role,
            appIdentifier: request.appIdentifier
        )

        let tiers = try deliveryTiers(
            available: [.ax, .pid, .global],
            via: request.via,
            noCursor: request.noCursor,
            strict: request.strict
        )

        func result(deliveryMethod: InputDeliveryMethod, resolved: ResolvedCoordinate?) -> ClickResult {
            ClickResult(
                metadataPath: nil,
                resolved: resolved,
                button: request.button,
                doubleClick: request.doubleClick,
                triple: request.triple,
                primeClick: request.primeClick,
                humanLike: request.humanLike,
                modifiers: modifiers,
                requestedVia: request.via,
                deliveryMethod: deliveryMethod,
                element: target.record
            )
        }

        var lastFailure: Error?
        for tier in tiers {
            do {
                switch tier {
                case .ax:
                    try performAXClick(request, modifiers: modifiers, target: target)
                    return result(deliveryMethod: .ax, resolved: nil)
                case .pid, .global:
                    let center = try elementCenter(of: target.record, tier: tier)
                    let destination: MouseEventDestination = tier == .pid ? .pid(target.app.pid) : .global
                    try mouseController.click(
                        at: center,
                        button: request.button,
                        doubleClick: request.doubleClick,
                        tripleClick: request.triple,
                        primeClick: request.primeClick,
                        humanLike: request.humanLike,
                        modifiers: modifiers,
                        destination: destination
                    )
                    return result(deliveryMethod: tier, resolved: elementCenterCoordinate(center))
                }
            } catch {
                lastFailure = error
            }
        }

        throw lastFailure
            ?? ScreenCommanderError.elementNotActionable("No delivery tier could act on the element.")
    }

    /// AX-tier click: coordinate-free `AXPress` (left) / `AXShowMenu` (right) on a
    /// freshly resolved element. Anything the AX action vocabulary cannot express
    /// throws `elementNotActionable` so the tier ladder can fall through.
    private func performAXClick(_ request: ClickRequest, modifiers: [String], target: ResolvedElementTarget) throws {
        guard !request.doubleClick, !request.triple, modifiers.isEmpty else {
            throw ScreenCommanderError.elementNotActionable(
                "AX actions cannot express double/triple clicks or modifiers; falls through to pid/global delivery."
            )
        }

        let action: String
        switch request.button {
        case .left:
            action = kAXPressAction
        case .right:
            action = kAXShowMenuAction
        case .middle:
            throw ScreenCommanderError.elementNotActionable("AX actions cannot express middle-clicks.")
        }

        guard target.record.enabled else {
            throw ScreenCommanderError.elementNotActionable(
                "Element '\(target.record.id)' (\(target.record.role)) is disabled."
            )
        }
        guard target.record.actions.contains(action) else {
            throw ScreenCommanderError.elementNotActionable(
                "Element '\(target.record.id)' (\(target.record.role)) does not support \(action); "
                    + "supported actions: \(target.record.actions.isEmpty ? "none" : target.record.actions.joined(separator: ", "))."
            )
        }

        let live = try accessibilityReader.resolve(id: target.record.id, app: target.app)
        try axActions.perform(action: action, on: live)
    }

    func scroll(_ request: ScrollRequest) async throws -> ScrollResult {
        if request.dx == 0 && request.dy == 0 {
            throw ScreenCommanderError.invalidArguments("At least one of --dx or --dy must be nonzero.")
        }

        if request.element != nil || request.elementID != nil {
            return try await elementScroll(request)
        }

        guard let x = request.x, let y = request.y else {
            throw ScreenCommanderError.invalidArguments("Provide x and y coordinates, or target an element with --element/--element-id.")
        }

        try permissions.ensureAccessibilityAccess(prompt: true)
        let destination = try await coordinateDestination(
            via: request.via,
            noCursor: request.noCursor,
            appIdentifier: request.appIdentifier
        )

        let metadataURL = resolvedURL(for: request.metadataPath ?? metadataStore.defaultLastMetadataURL.path)
        let metadata = try metadataStore.load(from: metadataURL)
        let resolved = try coordinateMapper.map(
            x: x,
            y: y,
            space: request.coordinateSpace,
            metadata: metadata
        )

        try mouseController.scroll(
            at: CGPoint(x: resolved.globalX, y: resolved.globalY),
            dx: request.dx,
            dy: request.dy,
            unit: request.unit,
            destination: destination
        )

        return ScrollResult(
            metadataPath: metadataURL.path,
            resolved: resolved,
            dx: request.dx,
            dy: request.dy,
            unit: request.unit,
            requestedVia: request.via,
            deliveryMethod: deliveryMethod(for: destination)
        )
    }

    private func elementScroll(_ request: ScrollRequest) async throws -> ScrollResult {
        guard request.x == nil, request.y == nil else {
            throw ScreenCommanderError.invalidArguments("Pass either coordinates or --element/--element-id, not both.")
        }
        if request.via == .ax {
            throw ScreenCommanderError.invalidArguments("scroll has no ax tier (there is no AX scroll action); use --via pid or global.")
        }

        try permissions.ensureAccessibilityAccess(prompt: true)
        let target = try await resolveElementTarget(
            element: request.element,
            elementID: request.elementID,
            role: request.role,
            appIdentifier: request.appIdentifier
        )

        let tiers = try deliveryTiers(
            available: [.pid, .global],
            via: request.via,
            noCursor: request.noCursor,
            strict: request.strict
        )

        var lastFailure: Error?
        for tier in tiers {
            do {
                let center = try elementCenter(of: target.record, tier: tier)
                let destination: MouseEventDestination = tier == .pid ? .pid(target.app.pid) : .global
                try mouseController.scroll(
                    at: center,
                    dx: request.dx,
                    dy: request.dy,
                    unit: request.unit,
                    destination: destination
                )
                return ScrollResult(
                    metadataPath: nil,
                    resolved: elementCenterCoordinate(center),
                    dx: request.dx,
                    dy: request.dy,
                    unit: request.unit,
                    requestedVia: request.via,
                    deliveryMethod: tier,
                    element: target.record
                )
            } catch {
                lastFailure = error
            }
        }

        throw lastFailure
            ?? ScreenCommanderError.elementNotActionable("No delivery tier could scroll the element.")
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

    func type(_ request: TypeRequest) async throws -> TypeResult {
        if let delay = request.delayMilliseconds, delay < 0 {
            throw ScreenCommanderError.invalidArguments("--delay-ms must be greater than or equal to zero.")
        }
        if request.via == .pid {
            throw ScreenCommanderError.invalidArguments("type has no pid tier; use --via ax (with --element) or --via global.")
        }

        if request.element != nil || request.elementID != nil {
            return try await elementType(request)
        }

        if request.via == .ax {
            throw ScreenCommanderError.invalidArguments("--via ax requires --element or --element-id.")
        }

        try permissions.ensureAccessibilityAccess(prompt: true)
        try typeViaKeyboard(request)

        return TypeResult(
            textLength: request.text.count,
            delayMilliseconds: request.delayMilliseconds,
            inputMode: request.inputMode,
            requestedVia: request.via,
            deliveryMethod: .global
        )
    }

    private func elementType(_ request: TypeRequest) async throws -> TypeResult {
        try permissions.ensureAccessibilityAccess(prompt: true)
        let target = try await resolveElementTarget(
            element: request.element,
            elementID: request.elementID,
            role: request.role,
            appIdentifier: request.appIdentifier
        )

        let tiers = try deliveryTiers(
            available: [.ax, .global],
            via: request.via,
            noCursor: false,
            strict: request.strict
        )

        func result(deliveryMethod: InputDeliveryMethod) -> TypeResult {
            TypeResult(
                textLength: request.text.count,
                delayMilliseconds: request.delayMilliseconds,
                inputMode: request.inputMode,
                requestedVia: request.via,
                deliveryMethod: deliveryMethod,
                element: target.record
            )
        }

        var lastFailure: Error?
        for tier in tiers {
            do {
                switch tier {
                case .ax:
                    guard target.record.enabled else {
                        throw ScreenCommanderError.elementNotActionable(
                            "Element '\(target.record.id)' (\(target.record.role)) is disabled."
                        )
                    }
                    let live = try accessibilityReader.resolve(id: target.record.id, app: target.app)
                    try axActions.setValue(request.text, on: live)
                    return result(deliveryMethod: .ax)
                case .global:
                    // Best-effort focus so keystrokes land in the intended field, then
                    // the existing keyboard path.
                    if let live = try? accessibilityReader.resolve(id: target.record.id, app: target.app) {
                        try? axActions.focus(on: live)
                    }
                    try typeViaKeyboard(request)
                    return result(deliveryMethod: .global)
                case .pid:
                    throw ScreenCommanderError.invalidArguments("type has no pid tier.")
                }
            } catch {
                lastFailure = error
            }
        }

        throw lastFailure
            ?? ScreenCommanderError.elementNotActionable("No delivery tier could type into the element.")
    }

    private func typeViaKeyboard(_ request: TypeRequest) throws {
        switch request.inputMode {
        case .paste:
            try keyboardController.typeByPasting(text: request.text)
        case .unicode:
            try keyboardController.type(text: request.text, delayMilliseconds: request.delayMilliseconds)
        }
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

    // MARK: - Element targeting (WP5)

    private struct ResolvedElementTarget {
        var app: ResolvedApp
        var record: AXElementRecord
    }

    /// Resolves `--element`/`--element-id` freshly against the current AX tree —
    /// ids are positional and must never be trusted across UI changes.
    private func resolveElementTarget(
        element: String?,
        elementID: String?,
        role: String?,
        appIdentifier: String?
    ) async throws -> ResolvedElementTarget {
        guard element == nil || elementID == nil else {
            throw ScreenCommanderError.invalidArguments("--element and --element-id are mutually exclusive.")
        }

        let app: ResolvedApp
        if let appIdentifier {
            app = try await targets.resolveApp(identifier: appIdentifier)
        } else if let frontmost = frontmostApp() {
            app = frontmost
        } else {
            throw ScreenCommanderError.invalidArguments(
                "Could not determine the frontmost application; pass --app <name|pid>."
            )
        }

        let tree = try accessibilityReader.tree(app: app, options: AXTreeOptions())

        if let elementID {
            guard let record = tree.elements.first(where: { $0.id == elementID }) else {
                throw ScreenCommanderError.elementNotFound(
                    "No element with id '\(elementID)' in '\(app.name)'. Ids are positional and "
                        + "change with the UI — re-read the tree with 'elements --app \(app.name)'."
                )
            }
            return ResolvedElementTarget(app: app, record: record)
        }

        guard let query = element,
              let record = AXElementMatcher.match(records: tree.elements, query: query, role: role) else {
            let roleHint = role.map { " with role '\($0)'" } ?? ""
            throw ScreenCommanderError.elementNotFound(
                "No element matching '\(element ?? "")'\(roleHint) in '\(app.name)'. "
                    + "Inspect candidates with 'elements --app \(app.name)'."
            )
        }
        return ResolvedElementTarget(app: app, record: record)
    }

    /// Tier ladder policy: `--via` forces exactly one tier (strict implied);
    /// `--no-cursor` removes `global`; `--strict` keeps only the preferred tier so a
    /// downgrade becomes an error instead of a recorded fallback.
    private func deliveryTiers(
        available: [InputDeliveryMethod],
        via: InputDeliveryMethod?,
        noCursor: Bool,
        strict: Bool
    ) throws -> [InputDeliveryMethod] {
        if let via {
            guard available.contains(via) else {
                throw ScreenCommanderError.invalidArguments(
                    "--via \(via.rawValue) is not supported here; use \(available.map(\.rawValue).joined(separator: " or "))."
                )
            }
            guard !(noCursor && via == .global) else {
                throw ScreenCommanderError.invalidArguments("--no-cursor cannot be combined with --via global.")
            }
            return [via]
        }

        var tiers = available
        if noCursor {
            tiers.removeAll { $0 == .global }
        }
        guard !tiers.isEmpty else {
            throw ScreenCommanderError.invalidArguments("--no-cursor leaves no usable delivery tier for this action.")
        }
        if strict {
            tiers = [tiers[0]]
        }
        return tiers
    }

    /// Delivery destination for coordinate-targeted actions. Coordinate actions keep
    /// the historical global default; `pid` delivery needs `--app` to know where to post.
    private func coordinateDestination(
        via: InputDeliveryMethod?,
        noCursor: Bool,
        appIdentifier: String?
    ) async throws -> MouseEventDestination {
        func pidDestination() async throws -> MouseEventDestination {
            guard let appIdentifier else {
                throw ScreenCommanderError.invalidArguments(
                    "pid delivery for a coordinate action requires --app <name|pid> so events can be posted to that app."
                )
            }
            let app = try await targets.resolveApp(identifier: appIdentifier)
            return .pid(app.pid)
        }

        switch via {
        case .ax:
            throw ScreenCommanderError.invalidArguments("--via ax requires --element or --element-id.")
        case .pid:
            return try await pidDestination()
        case .global:
            guard !noCursor else {
                throw ScreenCommanderError.invalidArguments("--no-cursor cannot be combined with --via global.")
            }
            return .global
        case nil:
            if noCursor {
                return try await pidDestination()
            }
            return .global
        }
    }

    private func deliveryMethod(for destination: MouseEventDestination) -> InputDeliveryMethod {
        switch destination {
        case .global:
            return .global
        case .pid:
            return .pid
        }
    }

    /// Center of the element's reported frame, in global top-left-origin points —
    /// the coordinate space CGEvents expect.
    private func elementCenter(of record: AXElementRecord, tier: InputDeliveryMethod) throws -> CGPoint {
        guard let bounds = record.boundsPoints else {
            throw ScreenCommanderError.elementNotActionable(
                "Element '\(record.id)' (\(record.role)) reports no frame; cannot deliver via \(tier.rawValue)."
            )
        }
        return CGPoint(x: bounds.x + bounds.w / 2, y: bounds.y + bounds.h / 2)
    }

    private func elementCenterCoordinate(_ center: CGPoint) -> ResolvedCoordinate {
        ResolvedCoordinate(
            inputX: Double(center.x),
            inputY: Double(center.y),
            space: .points,
            globalX: Double(center.x),
            globalY: Double(center.y)
        )
    }

    /// Streams UI-change events for an app until interrupted, timed out, or `--until`
    /// matched. `emit` is called once per event (the command prints NDJSON); the return
    /// value tells the command how to exit.
    ///
    /// Structured around an `AsyncThrowingStream<ObservedEvent, Error>` so WP8's MCP server can hold
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

        return try await withThrowingTaskGroup(of: ObserveOutcome?.self) { group in
            group.addTask {
                // A throwing stream lets the observer surface setup failures (e.g.
                // AXObserverCreate / registration failure ⇒ ax_tree_unavailable) as a
                // real error instead of a silent, indistinguishable end-of-stream.
                for try await event in stream {
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
                    // `.milliseconds(Int)` cannot overflow the way `UInt64(timeout) *
                    // 1_000_000` does, so an absurd-but-parseable --timeout-ms no longer
                    // traps at runtime (it was validated non-negative above).
                    try? await Task.sleep(for: .milliseconds(timeout))
                    if Task.isCancelled { return nil }
                    return predicate == nil ? .timedOut : .timedOutUnmet
                }
            }

            var outcome: ObserveOutcome = .completed
            for try await result in group {
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
