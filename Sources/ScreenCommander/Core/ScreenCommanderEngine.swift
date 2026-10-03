import AppKit
import CoreGraphics
import Foundation
import ScreenCommanderPresence

final class ScreenCommanderEngine {
    static let maximumElementTraversalDepth = 200
    static let maximumElementRecords = 10_000

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
    private let metadataFreshness: MetadataFreshnessChecking
    private let frontmostApp: () -> ResolvedApp?
    private let activateApp: (ResolvedApp) throws -> Void
    private let windowLocator: WindowLocating
    private let keyWindows: KeyWindowReading
    private let focusSampler: FocusSampling
    private let deliveryCapabilities: DeliveryCapabilities
    private let deliveryProfile: (pid_t) -> BackgroundDeliveryProfile
    private let bundleProfile: (URL?) -> BackgroundDeliveryProfile
    private let appCatalog: AppCataloging
    private let appLauncher: AppLaunching
    private let menuShortcuts: MenuShortcutResolving
    private let presence: PresenceControlling
    private let presenceSettings: PresenceSettings
    private let presencePolicy: PresencePolicy
    /// The wait between read-backs after an accessibility text write.
    private let textReadBackPause: () -> Void
    private let inputSerializer = InputSerializer()
    private let fileManager: FileManager
    private let statePaths: StatePaths
    private let now: () -> Date
    private let snapshots = ElementSnapshotStore()
    /// Serve mode: the last `state` snapshot per target (pid and window), so the next
    /// `app_state` call for that target returns a delta.
    private var stateSnapshotIDs: [String: String] = [:]
    private let stateSnapshotLock = NSLock()

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
        metadataFreshness: MetadataFreshnessChecking = MetadataFreshnessChecker(),
        frontmostApp: @escaping () -> ResolvedApp? = FrontmostApp.current,
        activateApp: @escaping (ResolvedApp) throws -> Void = AppActivator.activate,
        windowLocator: WindowLocating = CGWindowLocator(),
        keyWindows: KeyWindowReading = AXKeyWindowReader(),
        focusSampler: FocusSampling = LiveFocusSampler(),
        deliveryCapabilities: DeliveryCapabilities = .live(),
        deliveryProfile: @escaping (pid_t) -> BackgroundDeliveryProfile = DeliveryProfileResolver.uncached.profile(pid:),
        bundleProfile: @escaping (URL?) -> BackgroundDeliveryProfile = DeliveryProfileResolver.uncached.profile(bundleURL:),
        appCatalog: AppCataloging = AppCatalog(),
        appLauncher: AppLaunching = LiveAppLauncher(),
        menuShortcuts: MenuShortcutResolving = AXMenuShortcuts(),
        presence: PresenceControlling = DisabledPresenceController(),
        presenceSettings: PresenceSettings = PresenceSettings(defaultSession: PresenceSettings.defaultSessionID, cursorEnabled: true),
        presencePolicy: PresencePolicy = PresencePolicy(),
        textReadBackPause: @escaping () -> Void = { usleep(50_000) },
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
        self.metadataFreshness = metadataFreshness
        self.frontmostApp = frontmostApp
        self.activateApp = activateApp
        self.windowLocator = windowLocator
        self.keyWindows = keyWindows
        self.focusSampler = focusSampler
        self.deliveryCapabilities = deliveryCapabilities
        self.deliveryProfile = deliveryProfile
        self.bundleProfile = bundleProfile
        self.appCatalog = appCatalog
        self.appLauncher = appLauncher
        self.menuShortcuts = menuShortcuts
        self.presence = presence
        self.presenceSettings = presenceSettings
        self.presencePolicy = presencePolicy
        self.textReadBackPause = textReadBackPause
        self.statePaths = statePaths
        self.fileManager = fileManager
        self.now = now
    }

    /// `shareableContentTTL` caches the ~100–300 ms SCShareableContent enumeration for
    /// that many seconds. 0 (the CLI default) fetches fresh on every call; serve mode
    /// passes a short TTL so a warm server doesn't re-enumerate per tool call.
    /// `serve` gives the process its own default presence session ID.
    static func live(
        fileManager: FileManager = .default,
        shareableContentTTL: TimeInterval = 0,
        serve: Bool = false
    ) -> ScreenCommanderEngine {
        let statePaths = StatePaths(fileManager: fileManager)
        let metadataStore = SnapshotMetadataStore(
            fileManager: fileManager,
            lastMetadataURL: statePaths.lastMetadataURL
        )
        let contentProvider = ShareableContentProvider(ttl: shareableContentTTL)
        let clientName = serve ? "screencommander serve" : "screencommander"
        let profiles = DeliveryProfileResolver(statePaths: statePaths)

        return ScreenCommanderEngine(
            permissions: Permissions(),
            displays: Displays(
                contentProvider: contentProvider,
                overlayWindows: PresenceOverlayLocator(statePaths: statePaths)
            ),
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
            metadataFreshness: MetadataFreshnessChecker(),
            frontmostApp: FrontmostApp.current,
            activateApp: AppActivator.activate,
            windowLocator: CGWindowLocator(),
            keyWindows: AXKeyWindowReader(),
            focusSampler: LiveFocusSampler(),
            deliveryCapabilities: .live(),
            deliveryProfile: profiles.profile(pid:),
            bundleProfile: profiles.profile(bundleURL:),
            appCatalog: AppCatalog(),
            appLauncher: LiveAppLauncher(),
            menuShortcuts: AXMenuShortcuts(),
            presence: PresenceLaunch.controller(statePaths: statePaths, clientName: clientName),
            presenceSettings: PresenceSettings.resolve(serveProcessID: serve ? getpid() : nil),
            presencePolicy: PresencePolicy.resolve(serve: serve),
            statePaths: statePaths,
            fileManager: fileManager
        )
    }

    /// Lets go of everything this process holds in presence: `serve` calls it when
    /// its input ends, so its leases, sessions, and cursors go at once.
    func endPresence() {
        presence.disconnect()
    }

    func screenshot(_ request: ScreenshotRequest) async throws -> ScreenshotResult {
        try permissions.ensureScreenRecordingAccess(prompt: true)

        let imageURL = resolvedImageURL(explicitPath: request.outputPath, format: request.format)
        let metadataURL = resolvedMetadataURL(explicitPath: request.metadataPath, imageURL: imageURL)
        let lastMetadataURL = request.updateLastMetadata ? metadataStore.defaultLastMetadataURL : metadataURL

        // Window capture path
        if let windowIdentifier = request.windowIdentifier {
            let window = try await targets.resolveWindow(identifier: windowIdentifier, app: nil)
            let captured = try await capturer.capture(window: window, includeCursor: request.includeCursor)
            let encoded = try imageWriter.writeEncoded(image: captured.image, format: request.format, to: imageURL)
            let pixelSize = encoded.pixelSize

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
                image: captured.image,
                encodedImageData: encoded.data
            )
        }

        // Display capture path (existing behavior)
        let display = try await displays.resolveDisplay(identifier: request.displayIdentifier)
        let captured = try await capturer.capture(display: display, includeCursor: request.includeCursor)
        let encoded = try imageWriter.writeEncoded(image: captured.image, format: request.format, to: imageURL)
        let pixelSize = encoded.pixelSize

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
            image: captured.image,
                encodedImageData: encoded.data
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
        try await checkNotAborted()
        let priorApp = frontmostApp()
        // A focus guard left by an earlier background action would read this as a
        // steal and put the previous app back.
        await presence.endGuard(pid: app.pid)
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
        try validateCoordinateVia(request.via, foreground: request.foreground)

        let metadataURL = resolvedURL(for: request.metadataPath ?? metadataStore.defaultLastMetadataURL.path)
        let metadata = try metadataStore.load(from: metadataURL)
        let freshness = try checkMetadataFreshness(metadata, strict: request.strictMetadata)

        let resolved = try coordinateMapper.map(
            x: x,
            y: y,
            space: request.coordinateSpace,
            metadata: metadata
        )
        let point = CGPoint(x: resolved.globalX, y: resolved.globalY)
        let before = focusSampler.sample()

        let plan = try await pointerPlan(
            point: point,
            appIdentifier: request.appIdentifier,
            windowID: request.windowID,
            metadata: metadata,
            via: request.via,
            foreground: request.foreground,
            strict: request.strict
        )

        // Pre-click validation: what does the AX hit test say lives at this point?
        var verifiedTarget: AXElementRecord?
        if request.verifyTarget {
            verifiedTarget = try accessibilityReader.elementAt(globalPoint: point)
        }

        let (tier, presenceState) = try await performInput(
            pid: plan.targetPID,
            foreground: request.foreground,
            session: request.session,
            agentCursor: request.agentCursor,
            pointer: PresencePointer(point: point, windowID: plan.window?.windowID),
            pressCount: Self.clickCount(request)
        ) {
            try await deliverPointer(plan: plan) { destination in
                if destination == .global {
                    try await activateCoordinateTargetIfKnown(request: request, metadata: metadata, app: plan.app)
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
            }
        }

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
            deliveryMethod: tier,
            verifiedTarget: verifiedTarget,
            metadataFreshness: freshness,
            focus: await receipt(since: before, delivery: tier, presence: presenceState, pid: plan.targetPID),
            verified: .unknown,
            presence: presenceState
        )
    }

    private static func clickCount(_ request: ClickRequest) -> Int {
        request.triple ? 3 : (request.doubleClick ? 2 : 1)
    }

    private func elementClick(_ request: ClickRequest, modifiers: [String]) async throws -> ClickResult {
        guard request.x == nil, request.y == nil else {
            throw ScreenCommanderError.invalidArguments("Pass either coordinates or --element/--element-id, not both.")
        }
        guard !request.verifyTarget else {
            throw ScreenCommanderError.invalidArguments("--verify-target applies to coordinate clicks only.")
        }

        try permissions.ensureAccessibilityAccess(prompt: true)
        try validateVia(request.via, foreground: request.foreground)
        let target = try await resolveElementTarget(
            element: request.element,
            elementID: request.elementID,
            role: request.role,
            appIdentifier: request.appIdentifier,
            windowID: request.windowID
        )
        try ensureElementEnabled(target.record)
        let before = focusSampler.sample()

        let center = elementCenter(of: target.record)
        let window = elementWindow(target)
        let tiers = try deliveryTiers(
            hasAXTier: true,
            background: backgroundTiers(pid: target.app.pid, kind: .mouse, window: window, via: request.via),
            via: request.via,
            foreground: request.foreground,
            foregroundSkipsBackground: false,
            strict: request.strict,
            unavailableReason: elementUnavailableReason(target, window: window)
        )

        func result(
            deliveryMethod: InputDeliveryMethod,
            resolved: ResolvedCoordinate?,
            verified: ActionVerification = .unknown,
            axError: String? = nil
        ) -> ClickResult {
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
                element: target.record,
                focus: receipt(since: before, delivery: deliveryMethod),
                verified: verified,
                axError: axError
            )
        }

        var (outcome, presenceState) = try await performInput(
            pid: target.app.pid,
            foreground: request.foreground,
            session: request.session,
            agentCursor: request.agentCursor,
            pointer: elementPointer(center: center, window: window, pid: target.app.pid),
            pressCount: Self.clickCount(request)
        ) { () async throws -> ClickResult in
            var lastFailure: Error?
            for tier in tiers {
                do {
                    switch tier {
                    case .ax:
                        let pressed = try performAXClick(request, modifiers: modifiers, target: target)
                        return result(deliveryMethod: .ax, resolved: nil, verified: pressed.verified, axError: pressed.axError)
                    case .window, .focusAssisted, .global:
                        let center = try elementCenter(of: target.record, tier: tier)
                        if tier == .global {
                            try await prepareForegroundElement(target, point: center)
                        } else if let window {
                            try requireUncovered(window, at: center, app: target.app)
                        }
                        try mouseController.click(
                            at: center,
                            button: request.button,
                            doubleClick: request.doubleClick,
                            tripleClick: request.triple,
                            primeClick: request.primeClick,
                            humanLike: request.humanLike,
                            modifiers: modifiers,
                            destination: destination(for: tier, pid: target.app.pid, window: window)
                        )
                        return result(deliveryMethod: tier, resolved: elementCenterCoordinate(center))
                    }
                } catch let stop as LadderStop {
                    throw stop.error
                } catch {
                    lastFailure = error
                }
            }

            throw lastFailure
                ?? ScreenCommanderError.elementNotActionable("No delivery tier could act on the element.")
        }
        outcome.presence = presenceState
        outcome.focus = await guardChecked(outcome.focus, since: before, presence: presenceState, pid: target.app.pid)
        return outcome
    }

    /// Foreground only: focus is handled with app/window activation, not by spending
    /// a physical priming click. Coordinate clicks know a target only when the caller
    /// passes `--app`/`--window-id` or when window metadata is being reused; display
    /// screenshots have no safe way to infer the intended app from a point.
    private func activateCoordinateTargetIfKnown(
        request: ClickRequest,
        metadata: ScreenshotMetadata,
        app resolved: ResolvedApp?
    ) async throws {
        guard request.humanLike else {
            return
        }

        if let appIdentifier = request.appIdentifier {
            var app = resolved
            if app == nil {
                app = try await targets.resolveApp(identifier: appIdentifier)
            }
            if let app {
                try await activateIfNeeded(app)
            }
            return
        }

        if let windowID = request.windowID ?? metadata.windowID {
            let window = try await targets.resolveWindow(identifier: String(windowID), app: nil)
            guard window.info.pid > 0 else {
                throw ScreenCommanderError.appNotFound(
                    "Window \(windowID) has no owning app PID; cannot activate before click."
                )
            }
            try await activateIfNeeded(
                ResolvedApp(pid: window.info.pid, name: window.info.appName, bundleID: nil)
            )
        }
    }

    private func activateIfNeeded(_ app: ResolvedApp) async throws {
        guard frontmostApp()?.pid != app.pid else {
            return
        }
        // See `focus`: the guard must not undo an activation the caller asked for.
        await presence.endGuard(pid: app.pid)
        try activateApp(app)
        usleep(120_000)
    }

    private func checkMetadataFreshness(
        _ metadata: ScreenshotMetadata,
        strict: Bool
    ) throws -> MetadataFreshnessResult {
        let result = metadataFreshness.freshness(for: metadata)
        if strict, result.status == .stale {
            throw ScreenCommanderError.staleMetadata(result.reason)
        }
        return result
    }

    /// Ends a tier ladder at once with `error`, without trying the next tier.
    private struct LadderStop: Error {
        var error: Error
    }

    /// AX-tier click: coordinate-free `AXPress` (left) / `AXShowMenu` (right) on a
    /// freshly resolved element. Anything the AX action vocabulary cannot express,
    /// and an action the app refuses, throws `elementNotActionable` so the tier
    /// ladder can fall through to an event click.
    ///
    /// An answer that leaves open whether the press ran (`cannotComplete`, a
    /// timeout) is never retried as an event click, which could press twice. The
    /// element's value is read back instead: a change verifies the press, and
    /// otherwise the result is unverified and names the AX error. An element that
    /// is gone stops the ladder, since its old position now holds something else.
    private func performAXClick(
        _ request: ClickRequest,
        modifiers: [String],
        target: ResolvedElementTarget
    ) throws -> (verified: ActionVerification, axError: String?) {
        guard !request.doubleClick, !request.triple, modifiers.isEmpty else {
            throw ScreenCommanderError.elementNotActionable(
                "AX actions cannot express double/triple clicks or modifiers; falls through to window delivery."
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

        let live = try target.live ?? accessibilityReader.resolve(id: target.record.id, app: target.app)
        let valueBefore = axActions.readValue(of: live)
        let status = axActions.attempt(action: action, on: live)
        switch AXActionOutcome(status) {
        case .performed:
            return (.unknown, nil)
        case .refused:
            throw ScreenCommanderError.elementNotActionable(
                "AX action '\(action)' was refused (\(AXActions.describe(status))); falls through to event delivery."
            )
        case .elementGone:
            throw LadderStop(error: ScreenCommanderError.elementNotActionable(
                "Element '\(target.record.id)' went away before \(action) could run, so the UI changed. "
                    + "No event click was sent at its old position."
            ))
        case .unconfirmed:
            let valueAfter = axActions.readValue(of: live)
            let changed = valueBefore != nil && valueAfter != nil && valueBefore != valueAfter
            return (changed ? .checked(true) : .unknown, AXActions.errorName(status))
        }
    }

    func scroll(_ request: ScrollRequest) async throws -> ScrollResult {
        if let direction = request.direction {
            guard request.dx == 0, request.dy == 0 else {
                throw ScreenCommanderError.invalidArguments("--direction replaces --dx/--dy; pass one or the other.")
            }
            guard request.element != nil || request.elementID != nil else {
                throw ScreenCommanderError.invalidArguments("--direction scrolls an element; pass --element or --element-id.")
            }
            guard (1...50).contains(request.pages) else {
                throw ScreenCommanderError.invalidArguments("--pages must be between 1 and 50.")
            }
            return try await elementPageScroll(request, direction: direction)
        }

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
        try validateCoordinateVia(request.via, foreground: request.foreground)

        let metadataURL = resolvedURL(for: request.metadataPath ?? metadataStore.defaultLastMetadataURL.path)
        let metadata = try metadataStore.load(from: metadataURL)
        let freshness = try checkMetadataFreshness(metadata, strict: request.strictMetadata)
        let resolved = try coordinateMapper.map(
            x: x,
            y: y,
            space: request.coordinateSpace,
            metadata: metadata
        )
        let point = CGPoint(x: resolved.globalX, y: resolved.globalY)
        let before = focusSampler.sample()

        let plan = try await pointerPlan(
            point: point,
            appIdentifier: request.appIdentifier,
            windowID: request.windowID,
            metadata: metadata,
            via: request.via,
            foreground: request.foreground,
            strict: request.strict
        )
        let (tier, presenceState) = try await performInput(
            pid: plan.targetPID,
            foreground: request.foreground,
            session: request.session,
            agentCursor: request.agentCursor,
            pointer: PresencePointer(point: point, windowID: plan.window?.windowID)
        ) {
            try await deliverPointer(plan: plan) { destination in
                try mouseController.scroll(
                    at: point,
                    dx: request.dx,
                    dy: request.dy,
                    unit: request.unit,
                    destination: destination
                )
            }
        }

        return ScrollResult(
            metadataPath: metadataURL.path,
            resolved: resolved,
            dx: request.dx,
            dy: request.dy,
            unit: request.unit,
            requestedVia: request.via,
            deliveryMethod: tier,
            metadataFreshness: freshness,
            focus: await receipt(since: before, delivery: tier, presence: presenceState, pid: plan.targetPID),
            verified: .unknown,
            presence: presenceState
        )
    }

    private func elementScroll(_ request: ScrollRequest) async throws -> ScrollResult {
        guard request.x == nil, request.y == nil else {
            throw ScreenCommanderError.invalidArguments("Pass either coordinates or --element/--element-id, not both.")
        }
        if request.via == .ax {
            throw ScreenCommanderError.invalidArguments("--via ax scrolls by page; pass --direction (and --pages) instead of --dx/--dy.")
        }

        try permissions.ensureAccessibilityAccess(prompt: true)
        try validateVia(request.via, foreground: request.foreground)
        let target = try await resolveElementTarget(
            element: request.element,
            elementID: request.elementID,
            role: request.role,
            appIdentifier: request.appIdentifier,
            windowID: request.windowID
        )
        let before = focusSampler.sample()

        let center = try elementCenter(of: target.record, tier: request.via ?? .window)
        let window = elementWindow(target)
        let tiers = try deliveryTiers(
            hasAXTier: false,
            background: backgroundTiers(pid: target.app.pid, kind: .mouse, window: window, via: request.via),
            via: request.via,
            foreground: request.foreground,
            foregroundSkipsBackground: false,
            strict: request.strict,
            unavailableReason: elementUnavailableReason(target, window: window)
        )

        var (outcome, presenceState) = try await performInput(
            pid: target.app.pid,
            foreground: request.foreground,
            session: request.session,
            agentCursor: request.agentCursor,
            pointer: elementPointer(center: center, window: window, pid: target.app.pid)
        ) { () async throws -> ScrollResult in
            var lastFailure: Error?
            for tier in tiers {
                do {
                    if tier == .global {
                        try await prepareForegroundElement(target, point: center)
                    } else if let window {
                        try requireUncovered(window, at: center, app: target.app)
                    }
                    try mouseController.scroll(
                        at: center,
                        dx: request.dx,
                        dy: request.dy,
                        unit: request.unit,
                        destination: destination(for: tier, pid: target.app.pid, window: window)
                    )
                    return ScrollResult(
                        metadataPath: nil,
                        resolved: elementCenterCoordinate(center),
                        dx: request.dx,
                        dy: request.dy,
                        unit: request.unit,
                        requestedVia: request.via,
                        deliveryMethod: tier,
                        element: target.record,
                        focus: receipt(since: before, delivery: tier),
                        verified: .unknown
                    )
                } catch {
                    lastFailure = error
                }
            }

            throw lastFailure
                ?? ScreenCommanderError.elementNotActionable("No delivery tier could scroll the element.")
        }
        outcome.presence = presenceState
        outcome.focus = await guardChecked(outcome.focus, since: before, presence: presenceState, pid: target.app.pid)
        return outcome
    }

    func drag(_ request: DragRequest) async throws -> DragResult {
        try InputLimits.check(request.steps, in: InputLimits.dragSteps, "--steps")
        try InputLimits.check(request.durationMS, in: InputLimits.dragDurationMs, "--duration-ms")

        try permissions.ensureAccessibilityAccess(prompt: true)
        try validateCoordinateVia(nil, foreground: request.foreground)

        let metadataURL = resolvedURL(for: request.metadataPath ?? metadataStore.defaultLastMetadataURL.path)
        let metadata = try metadataStore.load(from: metadataURL)
        let freshness = try checkMetadataFreshness(metadata, strict: request.strictMetadata)
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
        let start = CGPoint(x: from.globalX, y: from.globalY)
        let before = focusSampler.sample()

        // The drag is addressed to the window under its starting point.
        let plan = try await pointerPlan(
            point: start,
            appIdentifier: request.appIdentifier,
            windowID: request.windowID,
            metadata: metadata,
            via: nil,
            foreground: request.foreground,
            strict: false
        )
        let end = CGPoint(x: to.globalX, y: to.globalY)
        let (tier, presenceState) = try await performInput(
            pid: plan.targetPID,
            foreground: request.foreground,
            session: request.session,
            agentCursor: request.agentCursor,
            pointer: PresencePointer(point: start, windowID: plan.window?.windowID),
            dragTo: end
        ) {
            try await deliverPointer(plan: plan) { destination in
                try mouseController.drag(
                    from: start,
                    to: end,
                    button: request.button,
                    steps: request.steps,
                    durationMS: request.durationMS,
                    destination: destination
                )
            }
        }

        return DragResult(
            metadataPath: metadataURL.path,
            from: from,
            to: to,
            button: request.button,
            steps: request.steps,
            durationMilliseconds: request.durationMS,
            metadataFreshness: freshness,
            deliveryMethod: tier,
            focus: await receipt(since: before, delivery: tier, presence: presenceState, pid: plan.targetPID),
            verified: .unknown,
            presence: presenceState
        )
    }

    func move(_ request: MoveRequest) async throws -> MoveResult {
        try InputLimits.check(request.dwellMS, in: InputLimits.dwellMs, "--dwell-ms")

        try permissions.ensureAccessibilityAccess(prompt: true)
        try validateCoordinateVia(nil, foreground: request.foreground)

        let metadataURL = resolvedURL(for: request.metadataPath ?? metadataStore.defaultLastMetadataURL.path)
        let metadata = try metadataStore.load(from: metadataURL)
        let freshness = try checkMetadataFreshness(metadata, strict: request.strictMetadata)
        let resolved = try coordinateMapper.map(
            x: request.x,
            y: request.y,
            space: request.coordinateSpace,
            metadata: metadata
        )
        let point = CGPoint(x: resolved.globalX, y: resolved.globalY)
        let before = focusSampler.sample()

        let plan = try await pointerPlan(
            point: point,
            appIdentifier: request.appIdentifier,
            windowID: request.windowID,
            metadata: metadata,
            via: nil,
            foreground: request.foreground,
            strict: false
        )
        let (tier, presenceState) = try await performInput(
            pid: plan.targetPID,
            foreground: request.foreground,
            session: request.session,
            agentCursor: request.agentCursor,
            pointer: PresencePointer(point: point, windowID: plan.window?.windowID)
        ) {
            try await deliverPointer(plan: plan) { destination in
                try mouseController.move(to: point, destination: destination)
            }
        }
        SleepTimer.sleep(milliseconds: request.dwellMS)

        return MoveResult(
            metadataPath: metadataURL.path,
            resolved: resolved,
            dwellMilliseconds: request.dwellMS,
            metadataFreshness: freshness,
            deliveryMethod: tier,
            focus: await receipt(since: before, delivery: tier, presence: presenceState, pid: plan.targetPID),
            verified: .unknown,
            presence: presenceState
        )
    }

    func type(_ request: TypeRequest) async throws -> TypeResult {
        if let delay = request.delayMilliseconds {
            try InputLimits.check(delay, in: InputLimits.typeDelayMs, "--delay-ms")
        }

        if request.element != nil || request.elementID != nil {
            return try await elementType(request)
        }
        var request = request
        request.windowID = keyboardWindowID(request.windowID, appIdentifier: request.appIdentifier, foreground: request.foreground)

        try permissions.ensureAccessibilityAccess(prompt: true)
        try validateVia(request.via, foreground: request.foreground)

        // Tier ax: the target app's focused text element, unless --via picks a key tier
        // or the app is Chromium-based (see `typesKeysFirst`). --replace needs that
        // field whatever the tier order, since its key fallback selects the field's
        // whole value first.
        var focusedField: AXElement?
        let (keyTarget, _) = try await keyboardTarget(appIdentifier: request.appIdentifier, windowID: request.windowID)
        let axFirst = request.via == .ax || (request.via == nil && !typesKeysFirst(pid: keyTarget.pid))
        if axFirst || request.replace {
            focusedField = axActions.focusedTextElement(pid: keyTarget.pid, windowID: request.windowID)
        }
        if axFirst {
            let app = keyTarget
            if let field = focusedField {
                let before = focusSampler.sample()
                do {
                    let (verified, presenceState) = try await performInput(
                        pid: app.pid,
                        foreground: request.foreground,
                        session: request.session,
                        agentCursor: request.agentCursor
                    ) {
                        try AXTextInput.write(
                            request.text, replace: request.replace, into: field, actions: axActions, pause: textReadBackPause
                        )
                    }
                    return TypeResult(
                        textLength: request.text.count,
                        delayMilliseconds: request.delayMilliseconds,
                        inputMode: Self.effectiveInputMode(request.inputMode, tier: .ax),
                        requestedVia: request.via,
                        deliveryMethod: .ax,
                        focus: await receipt(since: before, delivery: .ax, presence: presenceState, pid: app.pid),
                        verified: verified,
                        presence: presenceState,
                        replace: request.replace ? true : nil
                    )
                } catch let refused as AXTextInput.Refused {
                    if request.via == .ax || request.strict {
                        throw ScreenCommanderError.elementNotActionable(
                            "The focused text element in '\(app.name)' did not take the text through accessibility: \(refused.reason)"
                        )
                    }
                }
            } else if request.via == .ax {
                throw ScreenCommanderError.elementNotActionable(
                    "'\(app.name)' has no focused text element to type into through accessibility. "
                        + "Pass --element or --element-id, or a key tier with --via."
                )
            }
        }
        let before = focusSampler.sample()
        let delivery = try await deliverKeyboard(
            appIdentifier: request.appIdentifier,
            windowID: request.windowID,
            via: request.via,
            foreground: request.foreground,
            strict: request.strict,
            session: request.session,
            agentCursor: request.agentCursor
        ) { destination in
            try typeViaKeyboard(request, destination: destination, beforePosting: {
                guard request.replace else { return }
                // Lookup after keyboard preparation: Chromium may expose the focused
                // field only while its window is held key.
                guard let field = focusedField
                    ?? axActions.focusedTextElement(pid: keyTarget.pid, windowID: request.windowID) else {
                    throw ScreenCommanderError.elementNotActionable(
                        "--replace needs --element, --element-id, or a focused text field in the target app."
                    )
                }
                try Self.selectFullValueForKeyboardReplacement(field, actions: axActions)
            })
        }

        return TypeResult(
            textLength: request.text.count,
            delayMilliseconds: request.delayMilliseconds,
            inputMode: Self.effectiveInputMode(request.inputMode, tier: delivery.tier),
            requestedVia: request.via,
            deliveryMethod: delivery.tier,
            focus: await receipt(since: before, delivery: delivery.tier, presence: delivery.presence, pid: delivery.pid),
            verified: .unknown,
            presence: delivery.presence,
            replace: request.replace ? true : nil,
            keyWindowID: delivery.keyWindowID
        )
    }

    private func elementType(_ request: TypeRequest) async throws -> TypeResult {
        try permissions.ensureAccessibilityAccess(prompt: true)
        try validateVia(request.via, foreground: request.foreground)
        let target = try await resolveElementTarget(
            element: request.element,
            elementID: request.elementID,
            role: request.role,
            appIdentifier: request.appIdentifier,
            windowID: request.windowID
        )
        try ensureElementEnabled(target.record)
        let before = focusSampler.sample()

        // Keys must reach the element's own window. When that window is known but
        // cannot take keys (minimized, its app hidden), key events would land in
        // another window, so only accessibility can type into the element.
        let window = elementKeyboardWindow(target)
        let keysReachElement = target.windowID == nil || window != nil
        var tiers = try deliveryTiers(
            hasAXTier: true,
            background: keysReachElement
                ? backgroundTiers(pid: target.app.pid, kind: .keyboard, window: window, via: request.via)
                : [],
            via: request.via,
            foreground: request.foreground,
            foregroundSkipsBackground: false,
            strict: request.strict,
            unavailableReason: keysReachElement
                ? backgroundUnavailableReason(kind: .keyboard, window: window, app: target.app.name, pid: target.app.pid)
                : "The element's window \(target.windowID.map(String.init) ?? "") is not on screen, so it cannot be made key, "
                    + "and key events would go to another window."
        )
        if request.via == nil, tiers.count > 1, typesKeysFirst(pid: target.app.pid) {
            // Key events first, accessibility only when no key tier can run.
            tiers = tiers.filter { $0 != .ax } + [.ax]
        }

        /// `verified` runs after the receipt's settle, so keystrokes have landed.
        func result(
            deliveryMethod: InputDeliveryMethod,
            keyWindowID: CGWindowID? = nil,
            verified: () -> ActionVerification
        ) -> TypeResult {
            let focus = receipt(since: before, delivery: deliveryMethod)
            return TypeResult(
                textLength: request.text.count,
                delayMilliseconds: request.delayMilliseconds,
                inputMode: Self.effectiveInputMode(request.inputMode, tier: deliveryMethod),
                requestedVia: request.via,
                deliveryMethod: deliveryMethod,
                element: target.record,
                focus: focus,
                verified: verified(),
                replace: request.replace ? true : nil,
                keyWindowID: keyWindowID
            )
        }

        var (outcome, presenceState) = try await performInput(
            pid: target.app.pid,
            foreground: request.foreground,
            session: request.session,
            agentCursor: request.agentCursor
        ) { () async throws -> TypeResult in
            var lastFailure: Error?
            for tier in tiers {
                do {
                    let live = try target.live ?? accessibilityReader.resolve(id: target.record.id, app: target.app)
                    switch tier {
                    case .ax:
                        do {
                            let verified = try AXTextInput.write(
                                request.text, replace: request.replace, into: live, actions: axActions, pause: textReadBackPause
                            )
                            return result(deliveryMethod: .ax) { verified }
                        } catch let refused as AXTextInput.Refused {
                            throw ScreenCommanderError.elementNotActionable(
                                "Element '\(target.record.id)' did not take the text through accessibility: \(refused.reason)"
                            )
                        }
                    case .window, .focusAssisted, .global:
                        // Focus the field so keystrokes land in it. Focusing can select
                        // the whole value, so put the caret back where it was, or
                        // select everything for --replace.
                        let secure = axActions.isSecureText(live)
                        let priorValue = secure ? nil : axActions.readValue(of: live)
                        let priorSelection = axActions.readSelectedTextRange(of: live)
                        if !request.replace { try axActions.focus(on: live) }
                        if !request.replace, let priorSelection {
                            try? axActions.setSelectedTextRange(priorSelection, on: live)
                        }
                        var recipient: CGWindowID?
                        if tier == .global {
                            try await prepareForegroundElement(target, point: nil)
                        } else {
                            recipient = keyRecipient(tier: tier, pid: target.app.pid, window: window)
                        }
                        try typeViaKeyboard(request, destination: destination(for: tier, pid: target.app.pid, window: window), beforePosting: {
                            if request.replace {
                                try axActions.focus(on: live)
                                try Self.selectFullValueForKeyboardReplacement(live, actions: axActions)
                            }
                        })
                        return result(deliveryMethod: tier, keyWindowID: recipient) {
                            keyTypingVerification(
                                request: request, element: live, secure: secure, priorValue: priorValue, priorSelection: priorSelection
                            )
                        }
                    }
                } catch {
                    lastFailure = error
                }
            }

            throw lastFailure
                ?? ScreenCommanderError.elementNotActionable("No delivery tier could type into the element.")
        }
        outcome.presence = presenceState
        outcome.focus = await guardChecked(outcome.focus, since: before, presence: presenceState, pid: target.app.pid)
        return outcome
    }

    /// Chromium and Electron take accessibility text writes into inputs and text
    /// areas, but a write into a contenteditable fires no input event, so the page's
    /// own editor never learns about it and can put its old text back. `type` sends
    /// them key events first.
    private func typesKeysFirst(pid: pid_t) -> Bool {
        let toolkit = deliveryProfile(pid).toolkit
        return toolkit == .chromium || toolkit == .electron
    }

    /// What a read-back shows after typing into an element with key events. Keys may
    /// still be in flight, so a value that does not show the text yet is "unknown"
    /// rather than false. A secure field is never read.
    ///
    /// Only a change the typing made counts: the value must equal the expected
    /// splice, or hold the text at the caret where it went in. Text that was already
    /// in the field somewhere proves nothing.
    private func keyTypingVerification(
        request: TypeRequest,
        element: AXElement,
        secure: Bool,
        priorValue: String?,
        priorSelection: AXTextRange?
    ) -> ActionVerification {
        Self.typedTextVerification(
            text: request.text,
            replace: request.replace,
            before: secure ? nil : priorValue,
            selection: priorSelection,
            after: secure ? nil : axActions.readValue(of: element)
        )
    }

    static func typedTextVerification(
        text: String,
        replace: Bool,
        before: String?,
        selection: AXTextRange?,
        after: String?
    ) -> ActionVerification {
        guard let after, let before, !text.isEmpty, after != before else {
            return .unknown
        }
        if replace {
            return after == text ? .checked(true) : .unknown
        }
        if after == AXTextInput.splice(text, into: before, at: selection) {
            return .checked(true)
        }
        // The text sits where the caret was, though something else in the value
        // changed too (a substitution, or the app's own edit).
        let units = Array(after.utf16)
        let inserted = Array(text.utf16)
        let location = min(max(selection?.location ?? before.utf16.count, 0), before.utf16.count)
        if location + inserted.count <= units.count,
           Array(units[location..<(location + inserted.count)]) == inserted {
            return .checked(true)
        }
        return .unknown
    }

    private func ensureElementEnabled(_ record: AXElementRecord) throws {
        guard record.enabled else {
            throw ScreenCommanderError.elementNotActionable(
                "Element '\(record.id)' (\(record.role)) is disabled."
            )
        }
    }

    /// What delivered the text, for the result. Paste mode posts Command-V, which
    /// AppKit only handles through a key window, and an app in the background has
    /// none, so the paste would be dropped. The background tiers therefore type
    /// Unicode key events and never touch the pasteboard. Only `global` delivery
    /// (`--foreground`) pastes, and only when the caller asked for paste mode. The
    /// `ax` tier writes through accessibility, whatever mode was asked for.
    static func effectiveInputMode(_ requested: TextInputMode, tier: InputDeliveryMethod) -> TypedInputMode {
        switch tier {
        case .window, .focusAssisted:
            return .unicode
        case .ax:
            return .ax
        case .global:
            return requested == .paste ? .paste : .unicode
        }
    }

    /// Replacement requires proof of the complete value and the selection the app
    /// actually accepted. Secure values are never read to obtain that proof.
    static func selectFullValueForKeyboardReplacement(_ element: AXElement, actions: AXActionPerforming) throws {
        guard !actions.isSecureText(element), let value = actions.readValue(of: element) else {
            throw ScreenCommanderError.elementNotActionable(
                "--replace cannot prove a full-value selection for a secure or unreadable text field."
            )
        }
        let fullRange = AXTextRange(location: 0, length: value.utf16.count)
        try actions.setSelectedTextRange(fullRange, on: element)
        guard actions.readSelectedTextRange(of: element) == fullRange else {
            throw ScreenCommanderError.elementNotActionable(
                "--replace could not confirm that the text field selected its entire value."
            )
        }
    }

    private func typeViaKeyboard(
        _ request: TypeRequest,
        destination: InputEventDestination,
        beforePosting: () throws -> Void = {}
    ) throws {
        let mode = destination == .global ? request.inputMode : .unicode
        switch mode {
        case .paste:
            try keyboardController.typeByPasting(text: request.text, destination: destination, beforePosting: beforePosting)
        case .unicode:
            try keyboardController.type(text: request.text, delayMilliseconds: request.delayMilliseconds, destination: destination, beforePosting: beforePosting)
        }
    }

    func key(_ request: KeyRequest) async throws -> KeyResult {
        let chord = try KeyCodes.parseChord(request.chord)
        if case .system = chord.key, !request.foreground {
            throw ScreenCommanderError.backgroundDeliveryUnavailable(
                "'\(chord.normalized)' is a system key with no target app; it can only be sent globally."
            )
        }
        if let alias = chord.systemShortcut, !request.foreground {
            throw ScreenCommanderError.backgroundDeliveryUnavailable(KeyCodes.systemShortcutRefusal(alias))
        }
        if let name = KeyCodes.systemWideChord(chord), !request.foreground {
            throw ScreenCommanderError.backgroundDeliveryUnavailable(KeyCodes.systemWideChordRefusal(name))
        }

        try permissions.ensureAccessibilityAccess(prompt: true)
        let before = focusSampler.sample()
        var request = request
        request.windowID = keyboardWindowID(request.windowID, appIdentifier: request.appIdentifier, foreground: request.foreground)

        if !request.foreground, chord.flags.contains(.maskCommand), case .keyboard = chord.key {
            return try await commandShortcut(request, chord: chord, before: before)
        }

        let tier: InputDeliveryMethod
        let presenceState: ActionPresence
        var keyWindowID: CGWindowID?
        var keyPID: pid_t?
        if case .system = chord.key {
            // System keys have no target app; they only reach here with --foreground.
            (tier, presenceState) = try await performInput(
                pid: nil,
                foreground: true,
                session: request.session,
                agentCursor: request.agentCursor
            ) {
                try keyboardController.press(chord: chord, destination: .global)
                return InputDeliveryMethod.global
            }
        } else {
            let delivery = try await deliverKeyboard(
                appIdentifier: request.appIdentifier,
                windowID: request.windowID,
                via: nil,
                foreground: request.foreground,
                strict: false,
                session: request.session,
                agentCursor: request.agentCursor
            ) { destination in
                try keyboardController.press(chord: chord, destination: destination)
            }
            (tier, presenceState, keyWindowID, keyPID) = (delivery.tier, delivery.presence, delivery.keyWindowID, delivery.pid)
        }

        return KeyResult(
            normalizedChord: chord.normalized,
            deliveryMethod: tier,
            focus: await receipt(since: before, delivery: tier, presence: presenceState, pid: keyPID),
            verified: .unknown,
            presence: presenceState,
            keyWindowID: keyWindowID
        )
    }

    /// True when any step of the sequence is pressed with Command held, either as a
    /// chord modifier or after a `down:cmd` step.
    static func sequenceHoldsCommand(_ sequence: KeySequence) -> Bool {
        var held = false
        for step in sequence.steps {
            switch step {
            case .keyDown(.keyboard(let keyCode, _), let flags):
                if flags.contains(.maskCommand) || held { return true }
                if KeyboardController.modifierFlag(forKeyCode: keyCode) == .maskCommand { held = true }
            case .keyUp(.keyboard(let keyCode, _), _):
                if KeyboardController.modifierFlag(forKeyCode: keyCode) == .maskCommand { held = false }
            case .press(.keyboard, let flags):
                if flags.contains(.maskCommand) || held { return true }
            default:
                break
            }
        }
        return false
    }

    /// How long the target gets to handle a chord before its menu item is read back.
    static let menuValidationSettleMicroseconds: useconds_t = 60_000

    /// A Command chord sent to a background app.
    ///
    /// AppKit sends a menu command with no fixed target, and a view's own shortcut,
    /// through the key window, and an app in the background has none. So:
    ///
    /// 1. With an on-screen window and the focus-record symbols, the target's window
    ///    is made key for the length of the action (`focusAssisted`). A chord that
    ///    resolves to a menu item is pressed through Accessibility when the item
    ///    reads enabled, and `menuItem` names it. AppKit refreshes `AXEnabled` only
    ///    when something makes it revalidate its menus, so an item that still reads
    ///    disabled gets the chord as key events instead, which makes AppKit validate
    ///    it on the spot, and is read back afterwards: still disabled fails with
    ///    `element_not_actionable`. Any other chord goes out as key events.
    /// 2. Without a key window, only a menu item can be reached: it is pressed
    ///    through Accessibility when it reads enabled (`ax`). A chord that is not
    ///    a menu item fails with `background_delivery_unavailable`, because key
    ///    events would arrive and do nothing.
    private func commandShortcut(_ request: KeyRequest, chord: ParsedKeyChord, before: FocusSample) async throws -> KeyResult {
        let (app, window) = try await keyboardTarget(appIdentifier: request.appIdentifier, windowID: request.windowID)
        let canMakeKey = window != nil && deliveryCapabilities.focusRecords && deliveryCapabilities.windowLocation
        let appName = "'\(app.name)'"
        var item = menuShortcuts.match(chord: chord, pid: app.pid)

        if item == nil, !canMakeKey {
            throw ScreenCommanderError.backgroundDeliveryUnavailable(
                "No menu item in \(appName) uses \(chord.normalized), and a Command shortcut outside the menus "
                    + "only works in a key window. "
                    + (window == nil
                        ? "\(appName) has no on-screen window to make key."
                        : "The focus-record symbols that make a background window key are missing (see 'doctor').")
                    + " Use --foreground to send it to the frontmost app."
            )
        }

        func press(_ found: MenuShortcutItem) throws -> MenuShortcutItem {
            var current = found
            var status = menuShortcuts.press(current)
            if status == .invalidUIElement {
                // The app rebuilt its menus since the map was cached.
                menuShortcuts.invalidate(pid: app.pid)
                guard let fresh = menuShortcuts.match(chord: chord, pid: app.pid) else {
                    throw ScreenCommanderError.elementNotActionable(
                        "The menu item for \(chord.normalized) in \(appName) disappeared before it could be pressed."
                    )
                }
                current = fresh
                status = menuShortcuts.press(current)
            }
            guard status == .success else {
                throw ScreenCommanderError.inputSynthesisFailed(
                    "Pressing '\(current.pathDescription)' in \(appName) failed (AXError \(status.rawValue))."
                )
            }
            return current
        }

        let (outcome, presenceState) = try await performInput(
            pid: app.pid,
            foreground: false,
            session: request.session,
            agentCursor: request.agentCursor
        ) { () async throws -> (InputDeliveryMethod, MenuShortcutItem?) in
            guard canMakeKey, let window else {
                // No key window is possible: only an enabled menu item can be reached.
                guard let found = item else {
                    throw ScreenCommanderError.backgroundDeliveryUnavailable("No menu item uses \(chord.normalized).")
                }
                // A menu command without a fixed target acts on the app's key window,
                // so a named window that is not key would not get it.
                if let windowID = request.windowID, let key = keyWindows.keyWindowID(pid: app.pid), key != windowID {
                    throw ScreenCommanderError.backgroundDeliveryUnavailable(
                        "Window \(windowID) cannot be made key, and '\(found.pathDescription)' would act on window \(key), "
                            + "the key window in \(appName)."
                    )
                }
                guard menuShortcuts.isEnabled(found) == true else {
                    throw ScreenCommanderError.backgroundDeliveryUnavailable(
                        "'\(found.pathDescription)' is disabled in \(appName), and it has no on-screen window that could "
                            + "be made key to enable it. Restore a window, or use --foreground."
                    )
                }
                item = try press(found)
                return (.ax, item)
            }

            // Menu commands go out without the authentication envelope, which skips
            // the route AppKit's menus listen on.
            let destination = InputEventDestination.focusAssisted(window, authenticatedKeyboard: false)
            if let found = item {
                try keyboardController.withPrepared(destination) {
                    if menuShortcuts.isEnabled(found) == true {
                        item = try press(found)
                        return
                    }
                    // Inside the prepared action the window is already key (checked
                    // by `prepare` when it was named), so the chord goes straight to
                    // the pid.
                    var keyWindow = window
                    keyWindow.requiresKeyFocus = false
                    try keyboardController.press(chord: chord, destination: .window(keyWindow))
                    usleep(Self.menuValidationSettleMicroseconds)
                    guard menuShortcuts.isEnabled(found) == true else {
                        throw ScreenCommanderError.elementNotActionable(
                            "'\(found.pathDescription)' is disabled in \(appName) even with its window key, so \(chord.normalized) did nothing."
                        )
                    }
                }
                return (.focusAssisted, item)
            }
            try keyboardController.press(chord: chord, destination: destination)
            return (.focusAssisted, nil)
        }

        let (tier, pressed) = outcome
        return KeyResult(
            normalizedChord: chord.normalized,
            deliveryMethod: tier,
            menuItem: pressed?.pathDescription,
            focus: await receipt(since: before, delivery: tier, presence: presenceState, pid: app.pid),
            // A menu item reached in a key window is verified: it existed, read
            // enabled, and took the press or the chord. Without a key window an
            // enabled item can still have no target, and other key events are never
            // verified.
            verified: pressed != nil && tier == .focusAssisted ? .checked(true) : .unknown,
            presence: presenceState,
            keyWindowID: tier == .focusAssisted ? keyRecipient(tier: tier, pid: app.pid, window: window) : nil
        )
    }

    func keys(_ request: KeysRequest) async throws -> KeysResult {
        let sequence = try KeySequenceParser.parse(request.steps)
        let hasSystemKey = sequence.steps.contains { step in
            switch step {
            case .keyDown(.system, _), .keyUp(.system, _), .press(.system, _):
                return true
            default:
                return false
            }
        }
        if hasSystemKey, !request.foreground {
            throw ScreenCommanderError.backgroundDeliveryUnavailable(
                "The sequence contains a system key with no target app; system keys can only be sent globally."
            )
        }
        if let alias = sequence.systemShortcuts.first, !request.foreground {
            throw ScreenCommanderError.backgroundDeliveryUnavailable(KeyCodes.systemShortcutRefusal(alias))
        }
        if let name = KeyCodes.systemWideChord(in: sequence), !request.foreground {
            throw ScreenCommanderError.backgroundDeliveryUnavailable(KeyCodes.systemWideChordRefusal(name))
        }

        try permissions.ensureAccessibilityAccess(prompt: true)
        let before = focusSampler.sample()
        var request = request
        request.windowID = keyboardWindowID(request.windowID, appIdentifier: request.appIdentifier, foreground: request.foreground)

        // Command steps need the key window that only focusAssisted provides, so a
        // background sequence that holds Command uses that tier alone.
        let holdsCommand = !request.foreground && Self.sequenceHoldsCommand(sequence)
        let delivery = try await deliverKeyboard(
            appIdentifier: request.appIdentifier,
            windowID: request.windowID,
            via: nil,
            foreground: request.foreground,
            strict: false,
            session: request.session,
            agentCursor: request.agentCursor,
            commandShortcut: holdsCommand
        ) { destination in
            try keyboardController.run(sequence: sequence, destination: destination)
        }

        return KeysResult(
            normalizedSteps: sequence.steps.map { $0.normalized },
            deliveryMethod: delivery.tier,
            focus: await receipt(since: before, delivery: delivery.tier, presence: delivery.presence, pid: delivery.pid),
            verified: .unknown,
            presence: delivery.presence,
            keyWindowID: delivery.keyWindowID
        )
    }

    func elements(_ request: ElementsRequest) async throws -> ElementsResult {
        guard request.maxDepth >= 1 else {
            throw ScreenCommanderError.invalidArguments("--max-depth must be at least 1.")
        }
        guard request.maxDepth <= Self.maximumElementTraversalDepth else {
            throw ScreenCommanderError.invalidArguments(
                "--max-depth must be less than or equal to \(Self.maximumElementTraversalDepth)."
            )
        }
        guard request.maxElements >= 1 else {
            throw ScreenCommanderError.invalidArguments("--max-elements must be at least 1.")
        }
        guard request.maxElements <= Self.maximumElementRecords else {
            throw ScreenCommanderError.invalidArguments(
                "--max-elements must be less than or equal to \(Self.maximumElementRecords)."
            )
        }
        try InputLimits.check(request.maxValueLength, in: InputLimits.maxValueLength, "--max-value-length")
        if let cap = request.maxVisited, !(1...100_000).contains(cap) {
            throw ScreenCommanderError.invalidArguments("maxVisited must be between 1 and 100000.")
        }
        if let timeout = request.timeoutMS, !(1...60_000).contains(timeout) {
            throw ScreenCommanderError.invalidArguments("timeoutMs must be between 1 and 60000.")
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
        return try readElements(app: app, request: request)
    }

    /// Reads the tree for an already resolved app. `metadata` maps `boundsPixels`
    /// against a specific capture instead of last-screenshot.json.
    private func readElements(
        app: ResolvedApp,
        request: ElementsRequest,
        metadata explicitMetadata: (url: URL, metadata: ScreenshotMetadata)? = nil
    ) throws -> ElementsResult {
        let options = AXTreeOptions(
            windowID: request.windowID,
            allWindows: request.allWindows,
            maxDepth: request.maxDepth,
            maxElements: request.maxElements,
            roles: request.roles,
            visibleOnly: request.visibleOnly,
            maxValueLength: request.maxValueLength,
            profile: request.profile,
            maxVisited: request.maxVisited,
            timeoutMS: request.timeoutMS
        )
        let tree = try accessibilityReader.tree(app: app, options: options)

        // Pixel bounds are derived from the last screenshot's metadata when present;
        // no metadata (or elements outside its bounds) simply means no boundsPixels.
        var elements = tree.elements
        var metadataPath: String?
        let lastMetadataURL = metadataStore.defaultLastMetadataURL
        var reference: (url: URL, metadata: ScreenshotMetadata)?
        if request.profile == .full {
            if let explicitMetadata {
                reference = explicitMetadata
            } else if let metadata = try loadLastMetadataIfAvailable(from: lastMetadataURL) {
                reference = (lastMetadataURL, metadata)
            }
        }
        if let reference {
            let metadata = reference.metadata
            metadataPath = reference.url.path
            elements = elements.map { record in
                var record = record
                record.boundsPixels = record.boundsPoints.flatMap {
                    AXBoundsMapper.boundsPixels(for: $0, metadata: metadata)
                }
                return record
            }
        }

        var result = ElementsResult(
            app: app,
            windowID: request.windowID,
            metadataPath: metadataPath,
            axPrimed: tree.axPrimed,
            truncated: tree.truncated,
            elements: elements,
            text: request.includeText ? AXTextRenderer.render(elements) : nil,
            profile: request.profile == .full ? nil : request.profile.rawValue,
            visitedCount: tree.visitedCount,
            partialReason: tree.partialReason
        )
        if request.snapshot || request.since != nil {
            result = snapshots.update(result, request: request)
        }
        return result
    }

    // MARK: - App state, apps, launch

    /// One call for an app's window: a window capture (which also becomes the
    /// coordinate reference in last-screenshot.json) and its AX tree, with element IDs
    /// identical to `elements`. With `diff` (serve mode) the tree is a delta against
    /// the previous `state` of the same window when one is retained.
    func appState(_ request: AppStateRequest) async throws -> AppStateResult {
        guard (1...Self.maximumElementTraversalDepth).contains(request.maxDepth) else {
            throw ScreenCommanderError.invalidArguments(
                "--max-depth must be between 1 and \(Self.maximumElementTraversalDepth)."
            )
        }
        guard (1...Self.maximumElementRecords).contains(request.maxElements) else {
            throw ScreenCommanderError.invalidArguments(
                "--max-elements must be between 1 and \(Self.maximumElementRecords)."
            )
        }
        try permissions.ensureAccessibilityAccess(prompt: true)

        let app = try await targets.resolveApp(identifier: request.appIdentifier)
        // A window that is not on screen (minimized, its app hidden, or on another
        // Space) is captured through the window server; the capture recognizes it.
        let windowID: CGWindowID
        if let requested = request.windowID {
            windowID = try explicitWindow(requested, app: app).windowID
        } else if let front = windowLocator.frontWindow(pid: app.pid) {
            windowID = front.windowID
        } else if let offScreen = windowLocator.offScreenWindowIDs(pid: app.pid).first {
            windowID = offScreen
        } else {
            throw ScreenCommanderError.windowNotFound(
                "'\(app.name)' has no window to capture. "
                    + "Read its tree with 'elements --app \(app.name) --all-windows'."
            )
        }

        let shot = try await screenshot(ScreenshotRequest(
            displayIdentifier: "main",
            outputPath: nil,
            format: request.format,
            metadataPath: nil,
            includeCursor: false,
            updateLastMetadata: true,
            windowIdentifier: String(windowID)
        ))

        let key = "\(app.pid):\(windowID)"
        let since: String? = request.diff && !request.fullTree ? (request.since ?? stateSnapshotID(for: key)) : nil
        func elementsRequest(windowID: UInt32?) -> ElementsRequest {
            ElementsRequest(
                appIdentifier: String(app.pid),
                windowID: windowID,
                includeText: request.includeText,
                maxDepth: request.maxDepth,
                maxElements: request.maxElements,
                snapshot: request.diff,
                since: since
            )
        }
        let reference = (url: URL(fileURLWithPath: shot.metadataPath), metadata: shot.metadata)
        let tree: ElementsResult
        do {
            tree = try readElements(app: app, request: elementsRequest(windowID: windowID), metadata: reference)
        } catch ScreenCommanderError.invalidArguments where request.windowID == nil {
            // AX could not match the CGWindowID (the private lookup is missing or the
            // window is not in AXWindows). Another window's tree must never be paired
            // with this window's capture.
            throw ScreenCommanderError.axTreeUnavailable(
                "Accessibility lists no window matching the captured window \(windowID) of '\(app.name)', so its "
                    + "tree cannot be read. The capture is at \(shot.imagePath). Read the app's windows with "
                    + "'elements --app \(app.name) --all-windows'."
            )
        }
        if request.diff, let snapshotID = tree.snapshotId {
            setStateSnapshotID(snapshotID, for: key)
        }

        return AppStateResult(
            app: app,
            windowID: windowID,
            imagePath: shot.imagePath,
            metadataPath: shot.metadataPath,
            screenshot: shot.metadata,
            tree: tree,
            image: shot.image,
            encodedImageData: shot.encodedImageData
        )
    }

    private func stateSnapshotID(for key: String) -> String? {
        stateSnapshotLock.lock()
        defer { stateSnapshotLock.unlock() }
        return stateSnapshotIDs[key]
    }

    private func setStateSnapshotID(_ id: String, for key: String) {
        stateSnapshotLock.lock()
        stateSnapshotIDs[key] = id
        stateSnapshotLock.unlock()
    }

    /// Running apps, and installed apps unless `includeInstalled` is false.
    func apps(_ request: AppsRequest) -> AppsResult {
        let needle = request.filter?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func matches(name: String, bundleID: String?) -> Bool {
            guard let needle, !needle.isEmpty else { return true }
            return name.lowercased().contains(needle) || bundleID?.lowercased().contains(needle) == true
        }

        let running = appCatalog.runningApps().filter { matches(name: $0.name, bundleID: $0.bundleID) }
        guard request.includeInstalled else {
            return AppsResult(running: running, installed: nil, installedTruncated: nil)
        }
        let scan = appCatalog.installedApps()
        return AppsResult(
            running: running,
            installed: scan.apps.filter { matches(name: $0.name, bundleID: $0.bundleID) },
            installedTruncated: scan.truncated ? true : nil
        )
    }

    /// Launches an app without activating it and waits until it is running. The
    /// presence focus guard covers apps that activate themselves while launching; the
    /// focus receipt reports whether the frontmost app changed. An app that is already
    /// running is reported, not relaunched.
    func launch(_ request: LaunchRequest) async throws -> LaunchResult {
        guard (1...120_000).contains(request.timeoutMS) else {
            throw ScreenCommanderError.invalidArguments("--timeout-ms must be between 1 and 120000.")
        }
        let target = try appCatalog.resolveInstalled(identifier: request.appIdentifier)
        let targetPath = target.url.standardizedFileURL.path
        let running = appCatalog.runningApps().first(where: { entry in
            (target.bundleID != nil && entry.bundleID == target.bundleID)
                || entry.bundlePath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == targetPath
        })

        if presence.isEnabled {
            // An app that is not running yet gets the presence process started
            // first, so the guard is in place by the time the app finishes
            // launching. Either way the abort key stops the launch.
            let reply = running == nil ? await presence.status() : await presence.statusIfRunning()
            if case .success(let status) = reply, status.aborted {
                throw ScreenCommanderError.abortedByUser("The abort key was pressed.")
            }
        }

        if let running {
            let sample = focusSampler.sample()
            return LaunchResult(
                app: ResolvedApp(pid: running.pid, name: running.name, bundleID: running.bundleID),
                path: running.bundlePath ?? targetPath,
                alreadyRunning: true,
                ready: true,
                focus: FocusReceipt(before: sample, after: sample),
                presence: .disabled
            )
        }

        let session = resolvedSession(request.session)
        let before = focusSampler.sample()
        let pid = try await appLauncher.launch(url: target.url)

        var presenceState: ActionPresence = .disabled
        let guardLeaseMs = max(presencePolicy.guardLeaseMs, 5_000)
        if presence.isEnabled {
            switch await presence.beginLaunchGuard(pid: pid, leaseMs: guardLeaseMs, session: session, previousFrontmostPID: before.frontmostPid) {
            case .success:
                presenceState = .active
            case .failure, .unavailable:
                presenceState = .unavailable
            }
        }

        let ready = await appLauncher.waitUntilReady(pid: pid, timeout: TimeInterval(request.timeoutMS) / 1000)
        if presenceState == .active {
            // Apps often activate themselves in applicationDidFinishLaunching; renew
            // the lease from the moment the app is ready.
            _ = await presence.renewGuard(pid: pid, leaseMs: guardLeaseMs, session: session)
        }

        return LaunchResult(
            app: ResolvedApp(pid: pid, name: target.name, bundleID: target.bundleID),
            path: targetPath,
            alreadyRunning: false,
            ready: ready,
            focus: await receipt(since: before, delivery: nil, presence: presenceState, pid: pid),
            presence: presenceState
        )
    }

    /// `doctor --app`: the delivery profile for a running app, else an installed one.
    /// Reads the bundle only; sends no input.
    func appProfile(identifier: String) async throws -> AppProfileReport {
        do {
            let app = try await targets.resolveApp(identifier: identifier)
            // A running app picked by name prefix loses to an installed app with
            // exactly that name, so 'Cursor' means Cursor.app even while only some
            // other "Cursor..." process runs.
            if Int32(identifier) == nil, app.name.lowercased() != identifier.lowercased(),
               app.bundleID?.lowercased() != identifier.lowercased(),
               let installed = try? appCatalog.resolveInstalled(identifier: identifier),
               installed.name.lowercased() == identifier.lowercased()
                || installed.bundleID?.lowercased() == identifier.lowercased() {
                throw ScreenCommanderError.appNotFound("Prefer the installed '\(installed.name)'.")
            }
            let url = appCatalog.bundleURL(pid: app.pid)
            return AppProfileReport(
                name: app.name,
                bundleID: app.bundleID,
                pid: app.pid,
                path: url?.path,
                running: true,
                profile: bundleProfile(url)
            )
        } catch ScreenCommanderError.appNotFound {
            // Not running: classify the installed bundle.
        }

        let installed = try appCatalog.resolveInstalled(identifier: identifier)
        let path = installed.url.standardizedFileURL.path
        let running = appCatalog.runningApps().first { entry in
            (installed.bundleID != nil && entry.bundleID == installed.bundleID) || entry.bundlePath == path
        }
        return AppProfileReport(
            name: running?.name ?? installed.name,
            bundleID: installed.bundleID,
            pid: running?.pid,
            path: path,
            running: running != nil,
            profile: bundleProfile(installed.url)
        )
    }

    // MARK: - Text selection and AX actions

    /// Selects text in an element by UTF-16 range or by substring, then reads
    /// `AXSelectedTextRange` back to verify.
    func selectText(_ request: SelectTextRequest) async throws -> SelectTextResult {
        guard (request.range == nil) != (request.text == nil) else {
            throw ScreenCommanderError.invalidArguments("Pass exactly one of --range or --text.")
        }
        if let range = request.range {
            try InputLimits.check(range.location, in: InputLimits.textRange, "--range location")
            try InputLimits.check(range.length, in: InputLimits.textRange, "--range length")
        }
        if let text = request.text, text.isEmpty {
            throw ScreenCommanderError.invalidArguments("--text must not be empty.")
        }

        try permissions.ensureAccessibilityAccess(prompt: true)
        let target = try await resolveElementTarget(
            element: request.element,
            elementID: request.elementID,
            role: request.role,
            appIdentifier: request.appIdentifier,
            windowID: request.windowID
        )
        let live = try target.live ?? accessibilityReader.resolve(id: target.record.id, app: target.app)
        let range = try Self.selectionRange(request, value: axActions.readValue(of: live), record: target.record)
        let before = focusSampler.sample()

        let center = elementCenter(of: target.record)
        let window = elementWindow(target)
        var (outcome, presenceState) = try await performInput(
            pid: target.app.pid,
            foreground: false,
            session: request.session,
            agentCursor: request.agentCursor,
            pointer: elementPointer(center: center, window: window, pid: target.app.pid)
        ) { () async throws -> SelectTextResult in
            do {
                try axActions.setSelectedTextRange(range, on: live)
            } catch {
                // Many text views accept a selection only while they hold focus inside
                // their own window. AXFocused moves that focus without activating the app.
                try axActions.focus(on: live)
                try axActions.setSelectedTextRange(range, on: live)
            }
            let focus = receipt(since: before, delivery: nil)
            let selectedRange = axActions.readSelectedTextRange(of: live)
            return SelectTextResult(
                element: target.record,
                range: range,
                selectedRange: selectedRange,
                selectedText: axActions.readSelectedText(of: live),
                deliveryMethod: .ax,
                focus: focus,
                verified: selectedRange.map { .checked($0 == range) } ?? .unknown
            )
        }
        outcome.presence = presenceState
        outcome.focus = await guardChecked(outcome.focus, since: before, presence: presenceState, pid: target.app.pid)
        return outcome
    }

    /// The UTF-16 range to select: `--range` checked against the value's length,
    /// or the first match of `--text` (exact case first, then case-insensitive).
    static func selectionRange(_ request: SelectTextRequest, value: String?, record: AXElementRecord) throws -> AXTextRange {
        let length = value.map { ($0 as NSString).length }
        if let range = request.range {
            if let length, range.location + range.length > length {
                throw ScreenCommanderError.invalidArguments(
                    "--range \(range.location),\(range.length) runs past the end of the element's text (\(length) UTF-16 units)."
                )
            }
            return range
        }
        let needle = request.text ?? ""
        guard let value else {
            throw ScreenCommanderError.elementNotActionable(
                "Element '\(record.id)' (\(record.role)) exposes no readable AXValue to search; pass --range instead."
            )
        }
        let haystack = value as NSString
        var found = haystack.range(of: needle)
        if found.location == NSNotFound {
            found = haystack.range(of: needle, options: .caseInsensitive)
        }
        guard found.location != NSNotFound else {
            throw ScreenCommanderError.invalidArguments(
                "'\(needle)' does not occur in the text of element '\(record.id)' (\(record.role))."
            )
        }
        return AXTextRange(location: found.location, length: found.length)
    }

    /// Performs any AX action the element lists. Names it does not list are rejected
    /// with the ones it does.
    func performAction(_ request: PerformActionRequest) async throws -> PerformActionResult {
        let requested = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            throw ScreenCommanderError.invalidArguments("--name must not be empty.")
        }

        try permissions.ensureAccessibilityAccess(prompt: true)
        let target = try await resolveElementTarget(
            element: request.element,
            elementID: request.elementID,
            role: request.role,
            appIdentifier: request.appIdentifier,
            windowID: request.windowID
        )
        let available = target.record.actions
        guard let name = Self.matchActionName(requested, available: available) else {
            throw ScreenCommanderError.elementNotActionable(
                "Element '\(target.record.id)' (\(target.record.role)) does not list '\(requested)'; "
                    + "available actions: \(available.isEmpty ? "none" : available.joined(separator: ", "))."
            )
        }
        let before = focusSampler.sample()

        let center = elementCenter(of: target.record)
        let window = elementWindow(target)
        var (outcome, presenceState) = try await performInput(
            pid: target.app.pid,
            foreground: false,
            session: request.session,
            agentCursor: request.agentCursor,
            pointer: elementPointer(center: center, window: window, pid: target.app.pid),
            pressCount: name == kAXPressAction ? 1 : nil
        ) { () async throws -> PerformActionResult in
            let live = try target.live ?? accessibilityReader.resolve(id: target.record.id, app: target.app)
            try axActions.perform(action: name, on: live)
            return PerformActionResult(
                name: name,
                element: target.record,
                deliveryMethod: .ax,
                focus: receipt(since: before, delivery: .ax),
                verified: .unknown
            )
        }
        outcome.presence = presenceState
        outcome.focus = await guardChecked(outcome.focus, since: before, presence: presenceState, pid: target.app.pid)
        return outcome
    }

    /// Exact name, then case-insensitive, then with the `AX` prefix added.
    static func matchActionName(_ requested: String, available: [String]) -> String? {
        if available.contains(requested) {
            return requested
        }
        let lower = requested.lowercased()
        return available.first { $0.lowercased() == lower }
            ?? available.first { $0.lowercased() == "ax" + lower }
    }

    // MARK: - Page scrolling

    /// Scrolls an element by pages. Tier `ax` uses AX page actions, the scroll bar's
    /// page buttons, or a scroll-bar value write; the event tiers post pixel wheel
    /// events of about one element height per page at the element's center. Scroll
    /// bar positions read before and after decide `verified` when AX exposes them.
    private func elementPageScroll(_ request: ScrollRequest, direction: ScrollDirection) async throws -> ScrollResult {
        guard request.x == nil, request.y == nil else {
            throw ScreenCommanderError.invalidArguments("Pass either coordinates or --element/--element-id, not both.")
        }

        try permissions.ensureAccessibilityAccess(prompt: true)
        try validateVia(request.via, foreground: request.foreground)
        let target = try await resolveElementTarget(
            element: request.element,
            elementID: request.elementID,
            role: request.role,
            appIdentifier: request.appIdentifier,
            windowID: request.windowID
        )
        let before = focusSampler.sample()

        let center = elementCenter(of: target.record)
        let window = elementWindow(target)
        let tiers = try deliveryTiers(
            hasAXTier: true,
            background: backgroundTiers(pid: target.app.pid, kind: .mouse, window: window, via: request.via),
            via: request.via,
            foreground: request.foreground,
            foregroundSkipsBackground: false,
            strict: request.strict,
            unavailableReason: elementUnavailableReason(target, window: window)
        )

        func verification(_ start: Double?, _ end: Double?) -> ActionVerification {
            guard let start, let end else { return .unknown }
            return .checked(abs(end - start) > 0.000_1)
        }
        func result(tier: InputDeliveryMethod, dx: Int32, dy: Int32, unit: ScrollUnit, resolved: ResolvedCoordinate?,
                    verified: ActionVerification, axMethod: String?) -> ScrollResult {
            ScrollResult(
                metadataPath: nil,
                resolved: resolved,
                dx: dx,
                dy: dy,
                unit: unit,
                requestedVia: request.via,
                deliveryMethod: tier,
                element: target.record,
                focus: receipt(since: before, delivery: tier),
                verified: verified,
                direction: direction,
                pages: request.pages,
                axMethod: axMethod
            )
        }

        var (outcome, presenceState) = try await performInput(
            pid: target.app.pid,
            foreground: request.foreground,
            session: request.session,
            agentCursor: request.agentCursor,
            pointer: elementPointer(center: center, window: window, pid: target.app.pid)
        ) { () async throws -> ScrollResult in
            let live = try target.live ?? accessibilityReader.resolve(id: target.record.id, app: target.app)
            var lastFailure: Error?
            for tier in tiers {
                do {
                    switch tier {
                    case .ax:
                        let scrolled = try axActions.scrollByPage(live, direction: direction, pages: request.pages)
                        return result(tier: .ax, dx: 0, dy: 0, unit: .pixels, resolved: nil,
                                      verified: verification(scrolled.before, scrolled.after), axMethod: scrolled.method)
                    case .window, .focusAssisted, .global:
                        let point = try elementCenter(of: target.record, tier: tier)
                        if tier == .global {
                            try await prepareForegroundElement(target, point: point)
                        } else if let window {
                            try requireUncovered(window, at: point, app: target.app)
                        }
                        let step = Self.pageStep(direction: direction, bounds: target.record.boundsPoints)
                        let start = axActions.scrollPosition(of: live, direction: direction)
                        for _ in 0..<request.pages {
                            try mouseController.scroll(
                                at: point,
                                dx: step.dx,
                                dy: step.dy,
                                unit: step.unit,
                                destination: destination(for: tier, pid: target.app.pid, window: window)
                            )
                        }
                        var scrolled = result(
                            tier: tier,
                            dx: step.dx.multipliedReportingOverflow(by: Int32(request.pages)).partialValue,
                            dy: step.dy.multipliedReportingOverflow(by: Int32(request.pages)).partialValue,
                            unit: step.unit,
                            resolved: elementCenterCoordinate(point),
                            verified: .unknown,
                            axMethod: nil
                        )
                        // `result` settled before sampling focus, so the read below
                        // sees the scrolled position.
                        scrolled.verified = verification(start, axActions.scrollPosition(of: live, direction: direction))
                        return scrolled
                    }
                } catch let partial as AXPartialScrollError {
                    // Once AX has scrolled, replaying the request in a lower tier
                    // would add the completed pages a second time.
                    throw partial.underlyingError
                } catch {
                    lastFailure = error
                }
            }
            throw lastFailure
                ?? ScreenCommanderError.elementNotActionable("No delivery tier could scroll the element.")
        }
        outcome.presence = presenceState
        outcome.focus = await guardChecked(outcome.focus, since: before, presence: presenceState, pid: target.app.pid)
        return outcome
    }

    /// One page of wheel delta: 90% of the element's height (or width) in pixel
    /// units, else ten lines. Positive wheel values scroll up/left.
    static func pageStep(direction: ScrollDirection, bounds: RectD?) -> (dx: Int32, dy: Int32, unit: ScrollUnit) {
        let extent = bounds.map { direction.isVertical ? $0.h : $0.w } ?? 0
        let unit: ScrollUnit = extent >= 20 ? .pixels : .lines
        let magnitude = unit == .pixels ? Int32(clamping: Int((extent * 0.9).rounded())) : 10
        let signed = direction.isTowardEnd ? -magnitude : magnitude
        return direction.isVertical ? (0, signed, unit) : (signed, 0, unit)
    }

    private func loadLastMetadataIfAvailable(from url: URL) throws -> ScreenshotMetadata? {
        do {
            return try metadataStore.load(from: url)
        } catch {
            if fileManager.fileExists(atPath: url.path) {
                throw error
            }
            return nil
        }
    }

    // MARK: - Element targeting

    private struct ResolvedElementTarget {
        var app: ResolvedApp
        var record: AXElementRecord
        var live: AXElement? = nil
        /// The window that holds the element, nil when it is in none (the menu bar)
        /// or accessibility cannot say.
        var windowID: CGWindowID? = nil
    }

    /// Resolves `--element`/`--element-id` freshly against the current AX tree —
    /// ids are positional and must never be trusted across UI changes.
    ///
    /// `--element` searches the app's focused window, or `windowID` when given. An
    /// `--element-id` must lie in `windowID` when one is given. Without `--app`, a
    /// given window's owner is the app.
    private func resolveElementTarget(
        element: String?,
        elementID: String?,
        role: String?,
        appIdentifier: String?,
        windowID: UInt32? = nil
    ) async throws -> ResolvedElementTarget {
        guard element == nil || elementID == nil else {
            throw ScreenCommanderError.invalidArguments("--element and --element-id are mutually exclusive.")
        }

        let app: ResolvedApp
        if let appIdentifier {
            app = try await targets.resolveApp(identifier: appIdentifier)
            if let windowID {
                _ = try explicitWindow(windowID, app: app)
            }
        } else if let windowID {
            let window = try explicitWindow(windowID, app: nil)
            app = (try? await targets.resolveApp(identifier: String(window.pid)))
                ?? ResolvedApp(pid: window.pid, name: window.ownerName ?? "pid \(window.pid)", bundleID: nil)
        } else if let frontmost = frontmostApp() {
            app = frontmost
        } else {
            throw ScreenCommanderError.invalidArguments(
                "Could not determine the frontmost application; pass --app <name|pid>."
            )
        }

        if let elementID {
            let resolved = try accessibilityReader.readResolved(id: elementID, app: app)
            let own = accessibilityReader.windowID(ofElementID: elementID, app: app)
            if let windowID, let own, own != windowID {
                throw ScreenCommanderError.invalidArguments(
                    "Element '\(elementID)' is in window \(own), not window \(windowID). "
                        + "Read the window's elements with 'elements --app \(app.name) --window-id \(windowID)'."
                )
            }
            return ResolvedElementTarget(app: app, record: resolved.record, live: resolved.element, windowID: windowID ?? own)
        }
        let tree = try accessibilityReader.tree(app: app, options: AXTreeOptions(windowID: windowID))

        guard let query = element else {
            let roleHint = role.map { " with role '\($0)'" } ?? ""
            throw ScreenCommanderError.elementNotFound(
                "No element matching ''\(roleHint) in '\(app.name)'. "
                    + "Inspect candidates with 'elements --app \(app.name)'."
            )
        }

        switch AXElementMatcher.resolve(records: tree.elements, query: query, role: role) {
        case .found(let record):
            return ResolvedElementTarget(
                app: app,
                record: record,
                windowID: windowID ?? accessibilityReader.windowID(ofElementID: record.id, app: app)
            )
        case .ambiguous(let candidates):
            let roleHint = role.map { " with role '\($0)'" } ?? ""
            throw ScreenCommanderError.elementAmbiguous(
                "Element query '\(query)'\(roleHint) matched multiple candidates in '\(app.name)': "
                    + describeElementCandidates(candidates)
                    + ". Use --element-id or a narrower --role/--app target."
            )
        case nil:
            let roleHint = role.map { " with role '\($0)'" } ?? ""
            let scope = windowID.map { " window \($0)" } ?? ""
            throw ScreenCommanderError.elementNotFound(
                "No element matching '\(query)'\(roleHint) in '\(app.name)'\(scope). "
                    + "Inspect candidates with 'elements --app \(app.name)\(windowID.map { " --window-id \($0)" } ?? "")'."
            )
        }
    }

    private func describeElementCandidates(_ records: [AXElementRecord]) -> String {
        records
            .prefix(8)
            .map { record in
                var parts = ["id \(record.id)", record.role]
                if let title = record.title, !title.isEmpty {
                    parts.append("title '\(title)'")
                }
                if let description = record.description, !description.isEmpty {
                    parts.append("description '\(description)'")
                }
                if let value = record.value, !value.isEmpty {
                    parts.append("value '\(value)'")
                }
                return "(\(parts.joined(separator: ", ")))"
            }
            .joined(separator: ", ")
    }

    // MARK: - Delivery ladder

    private enum InputActionKind {
        case mouse
        case keyboard
    }

    /// A coordinate action's resolved tiers and, for background tiers, the window
    /// the events are addressed to.
    private struct PointerPlan {
        var tiers: [InputDeliveryMethod]
        var window: InputWindowTarget?
        /// The app the action is for, leased by the session: the window's owner in
        /// the background. With `--foreground`, the app `--app` or `--window-id`
        /// names, else the last screenshot's window's owner, else the owner of the
        /// topmost window at the point. Nil when none of those says.
        var targetPID: pid_t?
        /// The app `--app` named, once resolved.
        var app: ResolvedApp?
    }

    /// `--via global` is the HID tap, which only `--foreground` may use; `--via ax`
    /// needs an element.
    private func validateVia(_ via: InputDeliveryMethod?, foreground: Bool) throws {
        if via == .global, !foreground {
            throw ScreenCommanderError.invalidArguments("--via global requires --foreground.")
        }
    }

    private func validateCoordinateVia(_ via: InputDeliveryMethod?, foreground: Bool) throws {
        if via == .ax {
            throw ScreenCommanderError.invalidArguments("--via ax requires --element or --element-id.")
        }
        try validateVia(via, foreground: foreground)
    }

    /// Tier ladder policy, in order ax → window → focusAssisted → global.
    ///
    /// - `global` is present only with `--foreground`. Without it nothing activates an
    ///   app, posts to the HID tap, or moves the cursor; an empty ladder fails with
    ///   `background_delivery_unavailable`.
    /// - `foregroundSkipsBackground`: coordinate and bare keyboard actions keep the
    ///   pre-1.0 foreground behavior (activate, then HID tap) instead of trying the
    ///   background tiers first.
    /// - `--via` forces exactly one tier; `--strict` keeps only the first.
    private func deliveryTiers(
        hasAXTier: Bool,
        background: [InputDeliveryMethod],
        via: InputDeliveryMethod?,
        foreground: Bool,
        foregroundSkipsBackground: Bool,
        strict: Bool,
        unavailableReason: String
    ) throws -> [InputDeliveryMethod] {
        if let via {
            switch via {
            case .ax:
                guard hasAXTier else {
                    throw ScreenCommanderError.invalidArguments("--via ax requires --element or --element-id.")
                }
            case .global:
                guard foreground else {
                    throw ScreenCommanderError.invalidArguments("--via global requires --foreground.")
                }
            case .window, .focusAssisted:
                guard background.contains(via) else {
                    throw ScreenCommanderError.backgroundDeliveryUnavailable(
                        "The \(via.rawValue) tier is not available here: \(unavailableReason)"
                    )
                }
            }
            return [via]
        }

        var tiers: [InputDeliveryMethod] = hasAXTier ? [.ax] : []
        if !(foreground && foregroundSkipsBackground) {
            tiers += background
        }
        if foreground {
            tiers.append(.global)
        }
        guard !tiers.isEmpty else {
            throw ScreenCommanderError.backgroundDeliveryUnavailable(unavailableReason)
        }
        if strict {
            tiers = [tiers[0]]
        }
        return tiers
    }

    /// Background tiers for one target in the order this app should try them, minus
    /// any whose private symbols are missing or that need a window we do not have.
    /// An `unsupported` profile has none, unless `--via` forces a tier.
    private func backgroundTiers(
        pid: pid_t,
        kind: InputActionKind,
        window: InputWindowTarget?,
        via: InputDeliveryMethod?
    ) -> [InputDeliveryMethod] {
        let profile = deliveryProfile(pid)
        if profile.support == .unsupported, via == nil {
            return []
        }
        // The profile's ladder, minus `ax`. `--via` may force a background tier the
        // profile leaves out (plain window events for a Chromium app).
        var order = (kind == .keyboard ? profile.keyboardTiers : profile.mouseTiers).filter { $0 != .ax && $0 != .global }
        if let via, via == .window || via == .focusAssisted, !order.contains(via) {
            order.append(via)
        }
        return order.filter { tier in
            switch tier {
            case .window:
                return kind == .keyboard || (window != nil && deliveryCapabilities.windowLocation)
            case .focusAssisted:
                // The key-window primer is a window-addressed click, for keys too.
                return window != nil
                    && deliveryCapabilities.focusRecords
                    && deliveryCapabilities.windowLocation
            case .ax, .global:
                return false
            }
        }
    }

    private func backgroundUnavailableReason(kind: InputActionKind, window: InputWindowTarget?, app: String?, pid: pid_t) -> String {
        let profile = deliveryProfile(pid)
        if profile.support == .unsupported {
            return "\(app.map { "'\($0)'" } ?? "The target app") has no background input path. \(profile.reason) "
                + "Run 'doctor --app' for its profile."
        }
        if window == nil, kind == .mouse {
            return "\(app.map { "'\($0)'" } ?? "The target") has no on-screen window to address background input to."
        }
        return "the private SkyLight/CoreGraphics symbols this tier needs are missing on this macOS (see 'doctor')."
    }

    private func destination(for tier: InputDeliveryMethod, pid: pid_t, window: InputWindowTarget?) -> InputEventDestination {
        switch tier {
        case .global, .ax:
            return .global
        case .window:
            return window.map(InputEventDestination.window) ?? .pid(pid)
        case .focusAssisted:
            guard let window else {
                return .pid(pid)
            }
            let authenticated = deliveryProfile(pid).authenticatedKeyboard && deliveryCapabilities.authenticatedPost
            return .focusAssisted(window, authenticatedKeyboard: authenticated)
        }
    }

    /// Resolves tiers for a coordinate mouse action. Background tiers address the
    /// window from `--window-id`, else the last screenshot's window, else the topmost
    /// window under the point (limited to `--app` when given).
    private func pointerPlan(
        point: CGPoint,
        appIdentifier: String?,
        windowID: UInt32?,
        metadata: ScreenshotMetadata,
        via: InputDeliveryMethod?,
        foreground: Bool,
        strict: Bool
    ) async throws -> PointerPlan {
        if foreground, via == nil || via == .global {
            let app = try await appIdentifier.asyncMap { try await targets.resolveApp(identifier: $0) }
            let pid = app?.pid ?? foregroundTargetPID(point: point, windowID: windowID, metadata: metadata)
            return PointerPlan(tiers: [.global], window: nil, targetPID: pid, app: app)
        }

        let (window, untargeted) = try await pointerWindow(
            point: point,
            appIdentifier: appIdentifier,
            windowID: windowID,
            metadata: metadata
        )
        var unavailableReason = backgroundUnavailableReason(kind: .mouse, window: window, app: nil, pid: window.pid)
        if untargeted {
            unavailableReason = "The topmost thing at (\(Self.pointText(point))) is \(window.refusalDescription). "
                + unavailableReason + " --foreground reaches it with the real cursor."
        }
        let tiers = try deliveryTiers(
            hasAXTier: false,
            background: backgroundTiers(pid: window.pid, kind: .mouse, window: window, via: via),
            via: via,
            foreground: foreground,
            foregroundSkipsBackground: true,
            strict: strict,
            unavailableReason: unavailableReason
        )
        return PointerPlan(tiers: tiers, window: window, targetPID: window.pid)
    }

    /// See `PointerPlan.targetPID`. Reads window lists only and activates nothing.
    private func foregroundTargetPID(point: CGPoint, windowID: UInt32?, metadata: ScreenshotMetadata) -> pid_t? {
        if let windowID {
            return windowLocator.window(id: windowID)?.pid
        }
        if let metadataWindowID = metadata.windowID, let window = windowLocator.window(id: metadataWindowID) {
            return window.pid
        }
        guard let top = windowLocator.topWindow(at: point, pid: nil), !top.isWindowServerOwned, top.pid > 0 else {
            return nil
        }
        return top.pid
    }

    /// An open menu chooses an item only from the real pointer, and a click posted
    /// to its app closes it without choosing anything, so it is refused rather than
    /// reported as delivered.
    private static func refusePopUpMenu(_ window: InputWindowTarget, at point: CGPoint) throws {
        guard window.isPopUpMenu else {
            return
        }
        throw ScreenCommanderError.backgroundDeliveryUnavailable(
            "The topmost thing at (\(pointText(point))) is \(window.refusalDescription), an open menu. A menu takes "
                + "its choice only from the real pointer, and a background click would just close it. Choose the item "
                + "through accessibility ('click --element' with its title), or use --foreground."
        )
    }

    private static func pointText(_ point: CGPoint) -> String {
        "\(Int(point.x.rounded())), \(Int(point.y.rounded()))"
    }

    private func deliverPointer(
        plan: PointerPlan,
        _ deliver: (InputEventDestination) async throws -> Void
    ) async throws -> InputDeliveryMethod {
        var lastFailure: Error?
        for tier in plan.tiers {
            do {
                let destination: InputEventDestination
                if let window = plan.window {
                    destination = self.destination(for: tier, pid: window.pid, window: window)
                } else {
                    destination = .global
                }
                try await deliver(destination)
                return tier
            } catch {
                lastFailure = error
            }
        }
        throw lastFailure
            ?? ScreenCommanderError.backgroundDeliveryUnavailable("No delivery tier could deliver the input.")
    }

    /// The window a coordinate action is addressed to, and whether nothing named a
    /// target (so the window is simply whatever is topmost at the point).
    ///
    /// A named target (`--window-id`, the last window screenshot, or `--app`) gets
    /// the input and nothing else, whatever covers the point. With `--app`, that is
    /// the app's own topmost window at the point at any layer, so its pop-up menu or
    /// panel counts. With no target, the topmost window at the point at any layer
    /// gets it: a pop-up menu, a panel, the Dock, the menu bar, the desktop, or a
    /// document window. It is never the window underneath the topmost one.
    private func pointerWindow(
        point: CGPoint,
        appIdentifier: String?,
        windowID: UInt32?,
        metadata: ScreenshotMetadata
    ) async throws -> (window: InputWindowTarget, untargeted: Bool) {
        let app = try await appIdentifier.asyncMap { try await targets.resolveApp(identifier: $0) }
        if let windowID {
            return (try Self.requireOnScreen(explicitWindow(windowID, app: app)), false)
        }
        if let metadataWindowID = metadata.windowID,
           let window = windowLocator.window(id: metadataWindowID),
           app == nil || window.pid == app?.pid {
            // Never fall through to a hit test here: the point is relative to this
            // window, and whatever is on screen there now belongs to something else.
            return (try Self.requireOnScreen(window), false)
        }
        if let app {
            // A thumbnail in the Stage Manager strip is not where the app's window is.
            if let window = windowLocator.topWindow(at: point, pid: app.pid), !window.isStageManagerThumbnail {
                try Self.refusePopUpMenu(window, at: point)
                return (window, false)
            }
            if let window = windowLocator.frontWindow(pid: app.pid) {
                return (try Self.requireOnScreen(window), false)
            }
        } else if let window = windowLocator.topWindow(at: point, pid: nil) {
            let at = "The topmost thing at (\(Self.pointText(point))) is \(window.refusalDescription)"
            if window.isStageManagerThumbnail {
                throw ScreenCommanderError.backgroundDeliveryUnavailable(
                    "\(at), a Stage Manager thumbnail, and mouse events cannot be addressed to a thumbnail. "
                        + "--foreground clicks it with the real cursor."
                )
            }
            if window.isWindowServerOwned {
                throw ScreenCommanderError.backgroundDeliveryUnavailable(
                    "\(at), drawn by the window server itself, such as the menu bar, so no app takes background "
                        + "events there. --foreground clicks it with the real cursor."
                )
            }
            try Self.refusePopUpMenu(window, at: point)
            return (window, true)
        }
        if let app {
            throw ScreenCommanderError.backgroundDeliveryUnavailable(
                "'\(app.name)' has no on-screen window to address background input to."
            )
        }
        throw ScreenCommanderError.backgroundDeliveryUnavailable(
            "No window found at global point (\(point.x), \(point.y)) to address background input to; pass --app or --window-id."
        )
    }

    /// Where the agent cursor glides for an element action: the element's center,
    /// above its window. Nil (no glide) when the element sits in a window that is not
    /// on screen, since a cursor drawn there would point at some other app.
    private func elementPointer(center: CGPoint?, window: InputWindowTarget?, pid: pid_t) -> PresencePointer? {
        guard let center else {
            return nil
        }
        if window == nil, !windowLocator.offScreenWindowIDs(pid: pid).isEmpty {
            return nil
        }
        return PresencePointer(point: center, windowID: window?.windowID)
    }

    /// Window-addressed mouse events need the window on screen. A minimized window,
    /// a hidden app's window, or one on another Space is refused rather than clicked
    /// blind.
    private static func requireOnScreen(_ window: InputWindowTarget) throws -> InputWindowTarget {
        if window.isStageManagerThumbnail {
            throw ScreenCommanderError.backgroundDeliveryUnavailable(
                "Window \(window.windowID) is shown only as a Stage Manager thumbnail, so mouse events cannot be "
                    + "addressed to it. Act on an element instead (the ax tier works there), or bring its stage forward."
            )
        }
        guard window.isOnScreen else {
            throw ScreenCommanderError.backgroundDeliveryUnavailable(
                "Window \(window.windowID) is not on screen (it is minimized, its app is hidden, or it is on another Space), "
                    + "so mouse events cannot be addressed to it. Act on an element instead (the ax tier works there), "
                    + "or restore the window."
            )
        }
        return window
    }

    /// Any window by ID, on screen or not, checked against `app`.
    private func explicitWindow(_ windowID: UInt32, app: ResolvedApp?) throws -> InputWindowTarget {
        guard let window = windowLocator.window(id: windowID) else {
            throw ScreenCommanderError.windowNotFound("No window with ID \(windowID).")
        }
        if let app, app.pid != window.pid {
            throw ScreenCommanderError.invalidArguments(
                "Window \(windowID) belongs to pid \(window.pid), not '\(app.name)' (pid \(app.pid))."
            )
        }
        return window
    }

    /// The window an element's mouse events are addressed to: the window that holds
    /// the element (`--window-id` when given), never whichever of the app's windows
    /// happens to be topmost at the element's point. Nil when that window is not on
    /// screen or cannot be found, which leaves only the `ax` tier (and `global` with
    /// `--foreground`).
    private func elementWindow(_ target: ResolvedElementTarget) -> InputWindowTarget? {
        guard let id = target.windowID, let window = windowLocator.window(id: id),
              window.pid == target.app.pid, window.isOnScreen else {
            return nil
        }
        return window
    }

    /// The window an element's key events must reach: the element's own window,
    /// which delivery makes key first. Nil when that window cannot take keys. When
    /// accessibility cannot say which window holds the element, the app's front
    /// window, as before.
    private func elementKeyboardWindow(_ target: ResolvedElementTarget) -> InputWindowTarget? {
        guard let id = target.windowID else {
            return windowLocator.frontWindow(pid: target.app.pid)
        }
        guard let window = windowLocator.window(id: id), window.pid == target.app.pid, window.acceptsKeyboard else {
            return nil
        }
        return window.requiringKeyFocus()
    }

    private func elementUnavailableReason(_ target: ResolvedElementTarget, window: InputWindowTarget?) -> String {
        guard window == nil, deliveryProfile(target.app.pid).support != .unsupported else {
            return backgroundUnavailableReason(kind: .mouse, window: window, app: target.app.name, pid: target.app.pid)
        }
        let which = target.windowID.map { "window \($0)" } ?? "a window accessibility can name"
        return "Element '\(target.record.id)' in '\(target.app.name)' is not in \(which) that is on screen, "
            + "so events cannot be addressed to it. Only accessibility can act on it."
    }

    /// Window-addressed events reach their window however it is stacked, so they
    /// would click through another window of the same app lying over the element:
    /// a sheet, a panel, a pop-up menu, or another document. That is refused. Other
    /// apps' windows over the element do not matter, since nothing reaches them.
    private func requireUncovered(_ window: InputWindowTarget, at point: CGPoint, app: ResolvedApp) throws {
        guard let top = windowLocator.topWindow(at: point, pid: app.pid), top.isOnScreen,
              top.windowID != window.windowID else {
            return
        }
        throw ScreenCommanderError.backgroundDeliveryUnavailable(
            "The element's point (\(Self.pointText(point))) in window \(window.windowID) is covered by "
                + "\(top.refusalDescription) of the same app, and an event click there would go through it. "
                + "Deal with the covering window first, or act through accessibility."
        )
    }

    /// How long a raised window gets to come forward before its point is checked.
    static let foregroundRaiseSettleMicroseconds: useconds_t = 100_000

    /// `--foreground` element actions post through the HID tap, which hits whatever
    /// is on screen at the point. So the app is activated, the element's window is
    /// brought forward, and the point is checked before anything is posted: it must
    /// hit the element's window and, where accessibility can say, the element (or
    /// something inside it). For typing (`point` nil) the element's window must be
    /// key instead.
    private func prepareForegroundElement(_ target: ResolvedElementTarget, point: CGPoint?) async throws {
        try await activateIfNeeded(target.app)
        guard let windowID = target.windowID else {
            guard point == nil else {
                throw ScreenCommanderError.elementNotActionable(
                    "The window holding element '\(target.record.id)' could not be found, so a click at its point "
                        + "could land on something else. Nothing was clicked."
                )
            }
            return
        }
        try? axActions.raiseWindow(pid: target.app.pid, windowID: windowID)
        usleep(Self.foregroundRaiseSettleMicroseconds)

        guard let point else {
            if let key = keyWindows.keyWindowID(pid: target.app.pid), key != windowID {
                throw ScreenCommanderError.elementNotActionable(
                    "After activating '\(target.app.name)' and raising window \(windowID), window \(key) is key, "
                        + "so typed keys would land there. Nothing was typed."
                )
            }
            return
        }
        let top = windowLocator.topWindow(at: point, pid: nil)
        guard let top, top.windowID == windowID else {
            throw ScreenCommanderError.elementNotActionable(
                "After activating '\(target.app.name)' and raising window \(windowID), the element's point "
                    + "(\(Self.pointText(point))) is covered by \(top?.refusalDescription ?? "no window at all"). "
                    + "Nothing was clicked."
            )
        }
        // Raising a window reorders the app's windows, and with them the first
        // component of every element id, so the hit is compared by its window and
        // its path inside that window.
        if let hit = try? accessibilityReader.elementAt(globalPoint: point), !hit.id.isEmpty,
           accessibilityReader.windowID(ofElementID: hit.id, app: target.app).map({ $0 != windowID }) ?? false
            || !Self.isSameElementPath(Self.pathInWindow(hit.id), Self.pathInWindow(target.record.id)) {
            throw ScreenCommanderError.elementNotActionable(
                "The element's point (\(Self.pointText(point))) hits element '\(hit.id)' (\(hit.role)), "
                    + "not '\(target.record.id)' (\(target.record.role)). Nothing was clicked."
            )
        }
    }

    /// Two element paths name the same element, or one lies inside the other.
    static func isSameElementPath(_ a: [Substring], _ b: [Substring]) -> Bool {
        a.starts(with: b) || b.starts(with: a)
    }

    /// An element id without its first component, the window's place among the
    /// app's children.
    static func pathInWindow(_ id: String) -> [Substring] {
        Array(id.split(separator: ".").dropFirst())
    }

    /// The window a keyboard tier's keys go to, when that can be known: the window
    /// that must be made key, else the window `focusAssisted` primes for an app in
    /// the background, else the app's key window as accessibility reports it.
    private func keyRecipient(tier: InputDeliveryMethod, pid: pid_t, window: InputWindowTarget?) -> CGWindowID? {
        switch tier {
        case .ax, .global:
            return nil
        case .window:
            if let window, window.requiresKeyFocus {
                return window.windowID
            }
            return keyWindows.keyWindowID(pid: pid)
        case .focusAssisted:
            if let window, window.requiresKeyFocus || frontmostApp()?.pid != pid {
                return window.windowID
            }
            return keyWindows.keyWindowID(pid: pid)
        }
    }

    /// The window background keys go to when nothing else names one: the window of
    /// the last window screenshot (or `state`), when it still exists. That is the
    /// same window an untargeted coordinate click goes to. `--window-id` and `--app`
    /// win over it, and `--foreground` keys keep going to the frontmost app.
    private func keyboardWindowID(_ requested: UInt32?, appIdentifier: String?, foreground: Bool) -> UInt32? {
        if let requested {
            return requested
        }
        guard appIdentifier == nil, !foreground,
              let metadata = try? loadLastMetadataIfAvailable(from: metadataStore.defaultLastMetadataURL),
              let windowID = metadata.windowID, windowLocator.window(id: windowID) != nil else {
            return nil
        }
        return windowID
    }

    /// The app and window keyboard input goes to: `--window-id`'s owner, else
    /// `--app`, else the frontmost app. A `--window-id` window must get the keys, so
    /// it comes back marked `requiresKeyFocus`. Otherwise the window is the app's
    /// front window, nil when none is on screen; keys then go to the pid without a
    /// window stamp.
    private func keyboardTarget(appIdentifier: String?, windowID: UInt32?) async throws -> (ResolvedApp, InputWindowTarget?) {
        if let windowID {
            let named = try await appIdentifier.asyncMap { try await targets.resolveApp(identifier: $0) }
            let explicit = try explicitWindow(windowID, app: named)
            let app = named ?? ResolvedApp(pid: explicit.pid, name: "pid \(explicit.pid)", bundleID: nil)
            guard explicit.acceptsKeyboard else {
                // A window that is not on screen cannot be made key. Keys posted to
                // the pid reach it only while it is still the app's key window.
                if let key = keyWindows.keyWindowID(pid: explicit.pid), key != explicit.windowID {
                    throw ScreenCommanderError.backgroundDeliveryUnavailable(
                        "Window \(windowID) is not on screen, so it cannot be made key, and keys would go to "
                            + "window \(key) instead. Restore the window first."
                    )
                }
                return (app, nil)
            }
            return (app, explicit.requiringKeyFocus())
        }
        if let appIdentifier {
            let app = try await targets.resolveApp(identifier: appIdentifier)
            return (app, windowLocator.frontWindow(pid: app.pid))
        }
        if let frontmost = frontmostApp() {
            return (frontmost, windowLocator.frontWindow(pid: frontmost.pid))
        }
        throw ScreenCommanderError.backgroundDeliveryUnavailable(
            "Could not determine the frontmost app to send keys to; pass --app <name|pid>."
        )
    }

    /// Keyboard actions go to `--window-id`'s owner, else `--app`, else the frontmost
    /// app's pid. With `--foreground` (and no `--via`) they take the pre-1.0 path:
    /// activate the target if it is not frontmost, then post to the HID tap.
    private func deliverKeyboard(
        appIdentifier: String?,
        windowID: UInt32?,
        via: InputDeliveryMethod?,
        foreground: Bool,
        strict: Bool,
        session: String?,
        agentCursor: Bool?,
        commandShortcut: Bool = false,
        _ deliver: (InputEventDestination) throws -> Void
    ) async throws -> KeyboardDelivery {
        let (app, window) = try await keyboardTarget(appIdentifier: appIdentifier, windowID: windowID)

        var background = backgroundTiers(pid: app.pid, kind: .keyboard, window: window, via: via)
        var unavailableReason = backgroundUnavailableReason(kind: .keyboard, window: window, app: app.name, pid: app.pid)
        if commandShortcut {
            // Command shortcuts need a key window, which only focusAssisted makes.
            background = window != nil && deliveryCapabilities.focusRecords && deliveryCapabilities.windowLocation
                ? [.focusAssisted]
                : []
            unavailableReason = "Keys held with Command only work in a key window, and "
                + (window == nil
                    ? "'\(app.name)' has no on-screen window to make key."
                    : "the focus-record symbols that make a background window key are missing (see 'doctor').")
                + " Use 'key' for a single shortcut that is a menu item, or --foreground."
        }
        let tiers = try deliveryTiers(
            hasAXTier: false,
            background: background,
            via: via,
            foreground: foreground,
            foregroundSkipsBackground: true,
            strict: strict,
            unavailableReason: unavailableReason
        )

        let ((tier, recipient), presence) = try await performInput(
            pid: app.pid,
            foreground: foreground,
            session: session,
            agentCursor: agentCursor
        ) { () async throws -> (InputDeliveryMethod, CGWindowID?) in
            var lastFailure: Error?
            for tier in tiers {
                do {
                    if tier == .global, appIdentifier != nil || windowID != nil {
                        try await activateIfNeeded(app)
                        if let window, window.requiresKeyFocus {
                            try raiseForForegroundKeys(window, app: app)
                        }
                    }
                    let recipient = keyRecipient(tier: tier, pid: app.pid, window: window)
                    try deliver(destination(for: tier, pid: app.pid, window: window))
                    return (tier, recipient)
                } catch {
                    lastFailure = error
                }
            }
            throw lastFailure
                ?? ScreenCommanderError.backgroundDeliveryUnavailable("No delivery tier could deliver the keys.")
        }
        return KeyboardDelivery(tier: tier, presence: presence, keyWindowID: recipient, pid: app.pid)
    }

    /// What `deliverKeyboard` did: the tier, the presence state, the window the
    /// keys went to when that is known, and the app they went to.
    private struct KeyboardDelivery {
        var tier: InputDeliveryMethod
        var presence: ActionPresence
        var keyWindowID: CGWindowID?
        var pid: pid_t
    }

    /// `--foreground` keys with `--window-id`: after activation the named window is
    /// brought forward and must be key, or nothing is typed.
    private func raiseForForegroundKeys(_ window: InputWindowTarget, app: ResolvedApp) throws {
        guard keyWindows.keyWindowID(pid: window.pid) != window.windowID else {
            return
        }
        try? axActions.raiseWindow(pid: window.pid, windowID: window.windowID)
        usleep(Self.foregroundRaiseSettleMicroseconds)
        if let key = keyWindows.keyWindowID(pid: window.pid), key != window.windowID {
            throw ScreenCommanderError.elementNotActionable(
                "After activating '\(app.name)' and raising window \(window.windowID), window \(key) is key, "
                    + "so the keys would land there. Nothing was sent."
            )
        }
    }

    // MARK: - Presence

    /// Where the agent cursor glides before a pointer action: a global point,
    /// above the window the input is addressed to.
    private struct PresencePointer {
        var point: CGPoint
        var windowID: CGWindowID?
    }

    /// Runs one input action. Delivery is serialized per target pid, and every
    /// foreground action also holds one key shared by all HID tap delivery, so
    /// concurrent `serve` calls never interleave events.
    ///
    /// Without `--foreground`, the action goes through the presence process first:
    /// lease the target for this session (`target_busy` if another session holds
    /// it, `aborted_by_user` after the abort key), check status (yield while the
    /// user works in the target app, then `user_interrupted`), glide the cursor to
    /// `pointer` for pointer actions, and begin the focus guard. Then deliver,
    /// follow a drag to `dragTo`, and play the press animation for clicks. The
    /// guard lease expires on its own. An unreachable presence process never
    /// blocks delivery.
    ///
    /// With `--foreground` see `performForegroundInput`.
    private func performInput<T>(
        pid: pid_t?,
        foreground: Bool,
        session: String?,
        agentCursor: Bool?,
        pointer: PresencePointer? = nil,
        dragTo: CGPoint? = nil,
        pressCount: Int? = nil,
        _ deliver: () async throws -> T
    ) async throws -> (T, ActionPresence) {
        let keys = InputSerializer.keys(pid: pid, global: foreground)
        await inputSerializer.acquire(keys)
        do {
            let result: (T, ActionPresence)
            if foreground {
                result = try await performForegroundInput(pid: pid, session: session, deliver)
            } else {
                result = try await performInputHoldingTarget(
                    pid: pid,
                    session: session,
                    agentCursor: agentCursor,
                    pointer: pointer,
                    dragTo: dragTo,
                    pressCount: pressCount,
                    deliver
                )
            }
            await inputSerializer.release(keys)
            return result
        } catch {
            await inputSerializer.release(keys)
            throw error
        }
    }

    private func resolvedSession(_ requested: String?) -> String {
        requested.flatMap { $0.isEmpty ? nil : $0 } ?? presenceSettings.defaultSession
    }

    private func performInputHoldingTarget<T>(
        pid: pid_t?,
        session requestedSession: String?,
        agentCursor: Bool?,
        pointer: PresencePointer?,
        dragTo: CGPoint?,
        pressCount: Int?,
        _ deliver: () async throws -> T
    ) async throws -> (T, ActionPresence) {
        guard let pid, presence.isEnabled else {
            return (try await deliver(), .disabled)
        }
        let session = resolvedSession(requestedSession)
        let cursor = agentCursor ?? presenceSettings.cursorEnabled

        guard try await acquireLease(session: session, pid: pid) else {
            return (try await deliver(), .unavailable)
        }

        return try await holdingLease(session: session, pid: pid) {
            try await yieldToUser(session: session, pid: pid, foreground: false, cursor: cursor)

            if cursor, let pointer {
                let reply = await presence.moveCursor(
                    session: session,
                    to: PresencePoint(x: Double(pointer.point.x), y: Double(pointer.point.y)),
                    windowID: pointer.windowID
                )
                if let error = reply.error {
                    try Self.throwIfBlocking(error)
                }
            }

            _ = await presence.beginGuard(pid: pid, leaseMs: presencePolicy.guardLeaseMs, session: session)

            // Waiting and cursor motion can outlast a lease or the user's stop.
            // Confirm ownership and the abort flag immediately before posting.
            let leased = try await acquireLease(session: session, pid: pid)
            try await checkNotAborted()

            return try await holdingFocusGuard(session: session, pid: pid) {
                var follow: Task<Void, Never>?
                if cursor, let dragTo {
                    let presence = presence
                    follow = Task {
                        _ = await presence.moveCursor(
                            session: session,
                            to: PresencePoint(x: Double(dragTo.x), y: Double(dragTo.y)),
                            windowID: pointer?.windowID
                        )
                    }
                }

                let value: T
                do {
                    value = try await deliver()
                } catch {
                    await follow?.value
                    throw error
                }
                await follow?.value

                if cursor, let pressCount {
                    _ = await presence.pressCursor(session: session, count: pressCount)
                }
                if cursor {
                    // The next action's yield check puts the cursor back to idle.
                    _ = await presence.setCursorState(session: session, state: .loading)
                }
                return (value, leased ? .active : .unavailable)
            }
        }
    }

    /// A `--foreground` action posts through the HID event tap and moves the real
    /// cursor, so it draws no agent cursor and begins no focus guard. It still
    /// stops for the abort key, leases its target app when it has one (and fails
    /// with `target_busy` when another session holds it), and waits for the user
    /// to go quiet: the user's own keys and mouse share the HID stream with it, so
    /// any recent input counts, not only input in the target app. Talking to
    /// presence first also registers this process, so presence does not mistake
    /// the events it posts for the user's.
    private func performForegroundInput<T>(
        pid: pid_t?,
        session requestedSession: String?,
        _ deliver: () async throws -> T
    ) async throws -> (T, ActionPresence) {
        guard presence.isEnabled else {
            return (try await deliver(), .disabled)
        }
        let session = resolvedSession(requestedSession)
        if let pid {
            guard try await acquireLease(session: session, pid: pid) else {
                return (try await deliver(), .unavailable)
            }
            return try await holdingLease(session: session, pid: pid) {
                try await yieldToUser(session: session, pid: pid, foreground: true, cursor: false)
                let leased = try await acquireLease(session: session, pid: pid)
                try await checkNotAborted()
                return (try await deliver(), leased ? .active : .unavailable)
            }
        }
        // No target app to lease, such as a system key. Without a running presence
        // process there is no abort flag and no record of the user's input.
        guard case .success = await presence.statusIfRunning() else {
            return (try await deliver(), .unavailable)
        }
        let presence = presence
        try await yieldToUser(session: nil, pid: nil, foreground: true, cursor: false) {
            await presence.statusIfRunning()
        }
        try await checkNotAborted()
        return (try await deliver(), .active)
    }

    /// Takes or renews the session's lease on `pid`. False when presence cannot be
    /// reached. Throws `target_busy` and `aborted_by_user`.
    private func acquireLease(session: String, pid: pid_t) async throws -> Bool {
        let reply = await presence.acquire(
            session: session,
            pid: pid,
            holdMs: presencePolicy.leaseHoldMs,
            idleMs: presencePolicy.leaseIdleMs,
            lingerMs: presencePolicy.cursorLingerMs
        )
        switch reply {
        case .success:
            return true
        case .failure(let error):
            try Self.throwIfBlocking(error)
            return false
        case .unavailable:
            return false
        }
    }

    /// Keeps the app leased across every wait and the delivery itself.
    private func holdingLease<T>(session: String, pid: pid_t, _ action: () async throws -> T) async throws -> T {
        let presence = presence
        let interval = presencePolicy.leaseRenewInterval
        let (hold, idle, linger) = (presencePolicy.leaseHoldMs, presencePolicy.leaseIdleMs, presencePolicy.cursorLingerMs)
        let renewal = Task.detached {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                _ = await presence.acquire(session: session, pid: pid, holdMs: hold, idleMs: idle, lingerMs: linger)
            }
        }
        do {
            let value = try await action()
            renewal.cancel()
            await renewal.value
            return value
        } catch {
            renewal.cancel()
            await renewal.value
            throw error
        }
    }

    /// Extends the same guard during delivery, then leaves a full guard period
    /// after the action. Renewal preserves its restoration target and budget.
    private func holdingFocusGuard<T>(session: String, pid: pid_t, _ action: () async throws -> T) async throws -> T {
        let presence = presence
        let leaseMs = presencePolicy.guardLeaseMs
        let interval = max(0.001, Double(leaseMs) / 3000)
        let renewal = Task.detached {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                _ = await presence.renewGuard(pid: pid, leaseMs: leaseMs, session: session)
            }
        }
        do {
            let value = try await action()
            renewal.cancel()
            await renewal.value
            _ = await presence.renewGuard(pid: pid, leaseMs: leaseMs, session: session)
            return value
        } catch {
            renewal.cancel()
            await renewal.value
            _ = await presence.renewGuard(pid: pid, leaseMs: leaseMs, session: session)
            throw error
        }
    }

    /// Waits while the user is working where this action would land. The cursor
    /// shows `paused` while waiting. Each wait lasts until the presence process's
    /// quiet period should have passed, at most `userYieldCheckInterval`; after
    /// `userYieldTimeout` in total the action fails with `user_interrupted`.
    ///
    /// The user counts as working when real input went to the target app within
    /// the quiet period, whether or not any session leased it then, or into any
    /// app the session leases. For a foreground action, any real input counts.
    ///
    /// A cursor left `loading` by the previous action goes back to idle here, on
    /// every exit, so a failed or cursor-less action never leaves it loading.
    private func yieldToUser(
        session: String?,
        pid: pid_t?,
        foreground: Bool,
        cursor: Bool,
        fetch: (() async -> PresenceReply<PresenceStatus>)? = nil
    ) async throws {
        var waited: TimeInterval = 0
        var paused = false
        var wasLoading = false

        func restore() async {
            if let session, paused || wasLoading {
                _ = await presence.setCursorState(session: session, state: .idle)
            }
        }

        while true {
            let reply: PresenceReply<PresenceStatus>
            if let fetch {
                reply = await fetch()
            } else {
                reply = await presence.status()
            }
            guard case .success(let status) = reply else {
                break
            }
            if status.aborted {
                await restore()
                throw ScreenCommanderError.abortedByUser("The abort key was pressed.")
            }
            if let session, status.session(session)?.state == .loading {
                wasLoading = true
            }
            guard let sinceInput = userActivity(in: status, session: session, pid: pid, foreground: foreground) else {
                break
            }
            if waited >= presencePolicy.userYieldTimeout {
                await restore()
                throw ScreenCommanderError.userInterrupted(
                    foreground
                        ? "The user kept using the keyboard or mouse for \(Self.seconds(waited)), which a foreground action "
                            + "shares; the action was not delivered."
                        : "The user kept working in the target app for \(Self.seconds(waited)); the action was not delivered."
                )
            }
            if cursor, let session, !paused {
                _ = await presence.setCursorState(session: session, state: .paused)
                paused = true
            }
            let untilQuiet = max(0.05, presencePolicy.userQuietPeriod - sinceInput)
            let interval = min(presencePolicy.userYieldCheckInterval, untilQuiet, max(0.05, presencePolicy.userYieldTimeout - waited))
            await presencePolicy.sleep(interval)
            waited += interval
        }
        await restore()
    }

    /// Seconds since the input that makes the user count as active for this
    /// action, or nil while the user is quiet. See `yieldToUser`.
    private func userActivity(in status: PresenceStatus, session: String?, pid: pid_t?, foreground: Bool) -> TimeInterval? {
        let quiet = presencePolicy.userQuietPeriod
        var recent: [TimeInterval] = []
        if let session, let record = status.session(session), record.userActive {
            recent.append(TimeInterval(record.lastUserInputMsAgo ?? 0) / 1000)
        }
        if let pid, let ms = status.inputMsAgo(pid: pid) {
            recent.append(TimeInterval(ms) / 1000)
        }
        if foreground, let ms = status.lastUserInputMsAgo {
            recent.append(TimeInterval(ms) / 1000)
        }
        return recent.filter { $0 < quiet }.min()
    }

    /// Fails with `aborted_by_user` while the abort key is in force. Asks only a
    /// presence process that is already running: the flag lives only there.
    private func checkNotAborted() async throws {
        guard presence.isEnabled, case .success(let status) = await presence.statusIfRunning(), status.aborted else {
            return
        }
        throw ScreenCommanderError.abortedByUser("The abort key was pressed.")
    }

    /// Presence errors that must stop the action. Anything else degrades to
    /// delivering without presence.
    private static func throwIfBlocking(_ error: PresenceError) throws {
        switch error.code {
        case .targetBusy:
            throw ScreenCommanderError.targetBusy(error.message)
        case .abortedByUser:
            // The server's message already names `resume`; the error description adds it.
            throw ScreenCommanderError.abortedByUser("The abort key was pressed.")
        case .invalidRequest, .unsupportedVersion, .unknownMethod, .shuttingDown:
            return
        }
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f s", value)
    }

    /// Samples focus and the cursor again after a short settle and compares with
    /// `before`. `delivery` is the tier that delivered the action, nil when it sent
    /// no input events.
    private func receipt(since before: FocusSample, delivery: InputDeliveryMethod?) -> FocusReceipt {
        focusSampler.settle()
        return FocusReceipt(before: before, after: focusSampler.sample(), deliveredGlobally: delivery == .global)
    }

    /// `receipt(since:delivery:)` plus what the presence focus guard on `pid` did meanwhile.
    private func receipt(
        since before: FocusSample,
        delivery: InputDeliveryMethod?,
        presence actionPresence: ActionPresence,
        pid: pid_t?
    ) async -> FocusReceipt {
        let focus = receipt(since: before, delivery: delivery)
        return await guardChecked(focus, since: before, presence: actionPresence, pid: pid) ?? focus
    }

    /// Asks the presence process whether its focus guard on the action's target
    /// put the frontmost app back since `before` was sampled. A restore can land
    /// within tens of milliseconds, before the after-sample, so the frontmost app
    /// alone would look unchanged. When it did, the receipt says
    /// `guardRestored: true` and `preserved: false`. Restores for other apps,
    /// such as another session's target, do not count. Left unset when presence
    /// did not take part, the action has no target app, or presence is an older
    /// build that does not report restores.
    private func guardChecked(
        _ focus: FocusReceipt?,
        since before: FocusSample,
        presence actionPresence: ActionPresence,
        pid: pid_t?
    ) async -> FocusReceipt? {
        guard var focus, let pid, actionPresence == .active,
              case .success(let status) = await presence.status(),
              let restores = status.guardRestores else {
            return focus
        }
        // Wall-clock time on both sides: the sample's timestamp and the server's
        // "milliseconds ago" are both real time.
        let elapsedMs = Int((Date().timeIntervalSince(before.takenAt) * 1000).rounded(.up))
        let restored = restores.contains { restore in
            restore.pid == pid && (restore.lastRestoreMsAgo.map { $0 <= elapsedMs } ?? false)
        }
        focus.guardRestored = restored
        if restored {
            focus.preserved = false
        }
        return focus
    }

    /// Center of the element's reported frame, in global top-left-origin points —
    /// the coordinate space CGEvents expect.
    private func elementCenter(of record: AXElementRecord, tier: InputDeliveryMethod) throws -> CGPoint {
        guard let center = elementCenter(of: record) else {
            throw ScreenCommanderError.elementNotActionable(
                "Element '\(record.id)' (\(record.role)) reports no frame; cannot deliver via \(tier.rawValue)."
            )
        }
        return center
    }

    private func elementCenter(of record: AXElementRecord) -> CGPoint? {
        guard let bounds = record.boundsPoints else {
            return nil
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
    /// Structured around an `AsyncThrowingStream<ObservedEvent, Error>` so long-lived
    /// callers can hold observers warm without re-registering.
    func observe(
        _ request: ObserveRequest,
        emit: @escaping @Sendable (ObservedEvent) -> Void
    ) async throws -> ObserveOutcome {
        guard !request.kinds.isEmpty else {
            throw ScreenCommanderError.invalidArguments("--events selected no event kinds.")
        }
        if let timeout = request.timeoutMS {
            try InputLimits.check(timeout, in: InputLimits.observeTimeoutMs, "--timeout-ms")
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
        try InputLimits.check(olderThanHours, in: InputLimits.olderThanHours, "--older-than-hours")

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
        let uniqueSuffix = UUID().uuidString.lowercased().prefix(8)
        let filename = "Screenshot-\(timestamp)-\(uniqueSuffix).\(format.fileExtension)"
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

private extension Optional {
    func asyncMap<U>(_ transform: (Wrapped) async throws -> U) async rethrows -> U? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
