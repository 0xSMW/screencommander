import Foundation
import CoreGraphics
import ArgumentParser
import ScreenCaptureKit
import XCTest
@testable import ScreenCommander

private final class FakePermissions: PermissionChecking {
    private(set) var screenRecordingChecks = 0
    private(set) var accessibilityChecks = 0
    var allowScreenRecording = true
    var allowAccessibility = true

    func ensureScreenRecordingAccess(prompt: Bool) throws {
        screenRecordingChecks += 1
        if !allowScreenRecording {
            throw ScreenCommanderError.permissionDeniedScreenRecording
        }
    }

    func ensureAccessibilityAccess(prompt: Bool) throws {
        accessibilityChecks += 1
        if !allowAccessibility {
            throw ScreenCommanderError.permissionDeniedAccessibility
        }
    }
}

private final class NoopDisplays: DisplayResolving {
    func resolveDisplay(identifier: String) async throws -> ResolvedDisplay {
        throw ScreenCommanderError.invalidArguments("Display resolution should not be used in this test")
    }
}

private final class FakeDisplays: DisplayResolving {
    private let resolved: ResolvedDisplay

    init(resolved: ResolvedDisplay) {
        self.resolved = resolved
    }

    func resolveDisplay(identifier: String) async throws -> ResolvedDisplay {
        resolved
    }
}

private final class FakeCapturer: ScreenCapturing {
    private let captureResult: CapturedScreenshot
    private(set) var calls: Int = 0

    init(captureResult: CapturedScreenshot) {
        self.captureResult = captureResult
    }

    func capture(display: ResolvedDisplay, includeCursor: Bool) async throws -> CapturedScreenshot {
        calls += 1
        return captureResult
    }

    func capture(window: ResolvedWindow, includeCursor: Bool) async throws -> CapturedScreenshot {
        calls += 1
        return captureResult
    }
}

private final class FakeImageWriter: ImageWriting {
    private(set) var writes: [(url: URL, format: ImageFormat)] = []
    let returnedSize: SizeD

    init(returnedSize: SizeD) {
        self.returnedSize = returnedSize
    }

    func write(image: CGImage, format: ImageFormat, to url: URL) throws -> SizeD {
        writes.append((url: url, format: format))
        return returnedSize
    }
}

private final class FakeMetadataStore: SnapshotMetadataStoring {
    let defaultLastMetadataURL: URL
    private(set) var saved: [(metadata: ScreenshotMetadata, at: URL, updateLastAt: URL?)] = []
    private(set) var loadCalls: [URL] = []
    private var storedMetadataByPath: [String: ScreenshotMetadata] = [:]

    init(defaultLastMetadataURL: URL) {
        self.defaultLastMetadataURL = defaultLastMetadataURL
    }

    func save(metadata: ScreenshotMetadata, at metadataURL: URL, updateLastAt lastURL: URL?) throws {
        saved.append((metadata, metadataURL, lastURL))
        storedMetadataByPath[metadataURL.path] = metadata
        if let lastURL {
            storedMetadataByPath[lastURL.path] = metadata
        }
    }

    func load(from metadataURL: URL) throws -> ScreenshotMetadata {
        loadCalls.append(metadataURL)
        guard let metadata = storedMetadataByPath[metadataURL.path] else {
            throw ScreenCommanderError.metadataFailure("Missing metadata at \(metadataURL.path)")
        }
        return metadata
    }

    func seedLoad(_ metadata: ScreenshotMetadata, at url: URL) {
        storedMetadataByPath[url.path] = metadata
    }
}

private final class FakeMouseController: MouseControlling {
    struct ClickCall {
        let point: CGPoint
        let button: MouseButtonChoice
        let doubleClick: Bool
        let tripleClick: Bool
        let primeClick: Bool
        let humanLike: Bool
        let modifiers: [String]
        let destination: MouseEventDestination
    }
    struct ScrollCall {
        let point: CGPoint
        let dx: Int32
        let dy: Int32
        let unit: ScrollUnit
        let destination: MouseEventDestination
    }
    struct DragCall {
        let from: CGPoint
        let to: CGPoint
        let button: MouseButtonChoice
        let steps: Int
        let durationMS: Int
    }
    struct MoveCall {
        let point: CGPoint
    }

    private(set) var calls: [ClickCall] = []
    private(set) var scrollCalls: [ScrollCall] = []
    private(set) var dragCalls: [DragCall] = []
    private(set) var moveCalls: [MoveCall] = []

    /// Simulated per-destination failures for tier-fallback tests.
    var pidClickError: Error?
    var globalClickError: Error?
    var pidScrollError: Error?

    func click(
        at point: CGPoint,
        button: MouseButtonChoice,
        doubleClick: Bool,
        tripleClick: Bool,
        primeClick: Bool,
        humanLike: Bool,
        modifiers: [String],
        destination: MouseEventDestination
    ) throws {
        if case .pid = destination, let pidClickError {
            throw pidClickError
        }
        if destination == .global, let globalClickError {
            throw globalClickError
        }
        calls.append(
            ClickCall(
                point: point,
                button: button,
                doubleClick: doubleClick,
                tripleClick: tripleClick,
                primeClick: primeClick,
                humanLike: humanLike,
                modifiers: modifiers,
                destination: destination
            )
        )
    }

    func scroll(at point: CGPoint, dx: Int32, dy: Int32, unit: ScrollUnit, destination: MouseEventDestination) throws {
        if case .pid = destination, let pidScrollError {
            throw pidScrollError
        }
        scrollCalls.append(ScrollCall(point: point, dx: dx, dy: dy, unit: unit, destination: destination))
    }

    func drag(from start: CGPoint, to end: CGPoint, button: MouseButtonChoice, steps: Int, durationMS: Int) throws {
        dragCalls.append(DragCall(from: start, to: end, button: button, steps: steps, durationMS: durationMS))
    }

    func move(to point: CGPoint) throws {
        moveCalls.append(MoveCall(point: point))
    }
}

private final class FakeKeyboardController: KeyboardControlling {
    private(set) var typed: [(text: String, delayMilliseconds: Int?)] = []
    private(set) var pasted: [String] = []
    private(set) var pressed: [ParsedKeyChord] = []
    private(set) var systemPressed: [SystemKey] = []
    private(set) var runs: [KeySequence] = []

    func type(text: String, delayMilliseconds: Int?) throws {
        typed.append((text: text, delayMilliseconds: delayMilliseconds))
    }

    func typeByPasting(text: String) throws {
        pasted.append(text)
    }

    func press(chord: ParsedKeyChord) throws {
        pressed.append(chord)
    }

    func pressSystemKey(_ key: SystemKey) throws {
        systemPressed.append(key)
    }

    func run(sequence: KeySequence) throws {
        runs.append(sequence)
    }
}

private final class FakeRetentionManager: CaptureRetentionManaging {
    struct Call: Equatable {
        let directory: URL
        let olderThan: TimeInterval
        let now: Date
    }

    var result = CleanupResult(deletedCount: 0, deletedBytesApprox: 0)
    private(set) var calls: [Call] = []

    func pruneCaptures(in directory: URL, olderThan: TimeInterval, now: Date) throws -> CleanupResult {
        calls.append(Call(directory: directory, olderThan: olderThan, now: now))
        return result
    }
}

private final class FakeTargetResolver: TargetResolving {
    var apps: [String: ResolvedApp] = [:]
    var windowList: [WindowInfo] = []
    var windowByIdentifier: [String: WindowInfo] = [:]
    private(set) var resolveWindowCalls: [String] = []

    func resolveApp(identifier: String) async throws -> ResolvedApp {
        guard let app = apps[identifier] else {
            throw ScreenCommanderError.appNotFound("No app for '\(identifier)' in fake.")
        }
        return app
    }

    func listWindows(app: ResolvedApp?) async throws -> [WindowInfo] {
        if let app {
            return windowList.filter { $0.pid == app.pid }
        }
        return windowList
    }

    func resolveWindow(identifier: String, app: ResolvedApp?) async throws -> ResolvedWindow {
        resolveWindowCalls.append(identifier)
        guard let info = windowByIdentifier[identifier] else {
            throw ScreenCommanderError.windowNotFound("No window for '\(identifier)' in fake.")
        }
        // SCWindow cannot be constructed in tests; FakeCapturer ignores it.
        return ResolvedWindow(info: info, scWindow: nil)
    }
}

private final class FakeAccessibilityReader: AccessibilityReading {
    var treeResult = AXTreeResult(axPrimed: false, truncated: false, elements: [])
    /// When non-empty, each `tree` call consumes the next result (fresh-resolution tests).
    var treeResults: [AXTreeResult] = []
    var treeError: Error?
    private(set) var treeCalls: [(app: ResolvedApp, options: AXTreeOptions)] = []
    var elementAtResult: AXElementRecord?
    private(set) var elementAtCalls: [CGPoint] = []
    var resolveError: Error?
    private(set) var resolveCalls: [(id: String, app: ResolvedApp)] = []

    func tree(app: ResolvedApp, options: AXTreeOptions) throws -> AXTreeResult {
        treeCalls.append((app, options))
        if let treeError {
            throw treeError
        }
        if !treeResults.isEmpty {
            return treeResults.removeFirst()
        }
        return treeResult
    }

    func elementAt(globalPoint: CGPoint) throws -> AXElementRecord? {
        elementAtCalls.append(globalPoint)
        return elementAtResult
    }

    func resolve(id: String, app: ResolvedApp) throws -> AXElement {
        resolveCalls.append((id, app))
        if let resolveError {
            throw resolveError
        }
        // AXUIElementCreateApplication only mints a token — safe without TCC grants.
        return AXElement.application(pid: app.pid)
    }
}

private final class FakeAXActions: AXActionPerforming {
    var performError: Error?
    var setValueError: Error?
    var focusError: Error?
    private(set) var performedActions: [String] = []
    private(set) var setValues: [String] = []
    private(set) var focusCount = 0

    func perform(action: String, on element: AXElement) throws {
        if let performError {
            throw performError
        }
        performedActions.append(action)
    }

    func setValue(_ value: String, on element: AXElement) throws {
        if let setValueError {
            throw setValueError
        }
        setValues.append(value)
    }

    func focus(on element: AXElement) throws {
        if let focusError {
            throw focusError
        }
        focusCount += 1
    }
}

private final class FakeTargets: TargetResolving {
    var apps: [String: ResolvedApp] = [:]
    var windowList: [WindowInfo] = []
    private(set) var resolveCalls: [String] = []

    func resolveApp(identifier: String) async throws -> ResolvedApp {
        resolveCalls.append(identifier)
        guard let app = apps[identifier] else {
            throw ScreenCommanderError.invalidArguments("No running app matches '\(identifier)'.")
        }
        return app
    }

    func listWindows(app: ResolvedApp?) async throws -> [WindowInfo] {
        if let app {
            return windowList.filter { $0.pid == app.pid }
        }
        return windowList
    }

    func resolveWindow(identifier: String, app: ResolvedApp?) async throws -> ResolvedWindow {
        throw ScreenCommanderError.windowNotFound("resolveWindow(identifier:app:) should not be used in this test")
    }
}

private final class FakeObservationSource: ObservationSource, @unchecked Sendable {
    /// Events yielded (in order) when `events(...)` is called.
    var scriptedEvents: [ObservedEvent] = []
    /// When true, the stream never finishes on its own — it stays open until the
    /// consuming task is cancelled (drives timeout tests deterministically).
    var keepOpen = false
    /// When set, the stream finishes throwing this error after yielding scripted
    /// events — models an observer-setup failure (AXObserverCreate / registration).
    var setupError: Error?

    private(set) var requestedApp: ResolvedApp?
    private(set) var requestedKinds: Set<ObservedEventKind>?

    func events(app: ResolvedApp, kinds: Set<ObservedEventKind>) -> AsyncThrowingStream<ObservedEvent, Error> {
        requestedApp = app
        requestedKinds = kinds
        let events = scriptedEvents
        let keepOpen = keepOpen
        let setupError = setupError
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            if let setupError {
                continuation.finish(throwing: setupError)
            } else if !keepOpen {
                continuation.finish()
            }
        }
    }
}

private func make1x1Image() -> CGImage {
    let data = Data([255, 0, 0, 255])
    let provider = CGDataProvider(data: data as CFData)!
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
    return CGImage(
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private func tempStatePath(_ name: String) -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("screencommander-engine-tests", isDirectory: true)
        .appendingPathComponent(name)

    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

private struct InputEngineFixture {
    let engine: ScreenCommanderEngine
    let permissions: FakePermissions
    let metadataStore: FakeMetadataStore
    let mouse: FakeMouseController
    let keyboard: FakeKeyboardController
    let reader: FakeAccessibilityReader
    let axActions: FakeAXActions
    let targets: FakeTargets
    let state: StatePaths
}

private func makeInputEngineFixture(
    _ name: String,
    frontmostApp: ResolvedApp? = nil
) -> InputEngineFixture {
    let permissions = FakePermissions()
    let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath(name).path])
    let metadataStore = FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL)
    let mouse = FakeMouseController()
    let keyboard = FakeKeyboardController()
    let reader = FakeAccessibilityReader()
    let axActions = FakeAXActions()
    let targets = FakeTargets()
    let metadata = ScreenshotMetadata(
        capturedAtISO8601: "2026-02-21T00:00:00Z",
        displayID: 123,
        displayBoundsPoints: RectD(x: 100, y: 200, w: 400, h: 300),
        imageSizePixels: SizeD(w: 800, h: 600),
        pointPixelScale: 2,
        imagePath: "/tmp/test.png"
    )
    metadataStore.seedLoad(metadata, at: state.lastMetadataURL)

    let engine = ScreenCommanderEngine(
        permissions: permissions,
        displays: NoopDisplays(),
        capturer: FakeCapturer(
            captureResult: CapturedScreenshot(
                image: make1x1Image(),
                displayID: 123,
                displayBoundsPoints: CGRect(x: 100, y: 200, width: 400, height: 300),
                pointPixelScale: 2
            )
        ),
        imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
        metadataStore: metadataStore,
        coordinateMapper: CoordinateMapper(),
        mouseController: mouse,
        keyboardController: keyboard,
        retention: FakeRetentionManager(),
        accessibilityReader: reader,
        axActions: axActions,
        targets: targets,
        frontmostApp: { frontmostApp },
        statePaths: state,
        fileManager: .default,
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    return InputEngineFixture(
        engine: engine,
        permissions: permissions,
        metadataStore: metadataStore,
        mouse: mouse,
        keyboard: keyboard,
        reader: reader,
        axActions: axActions,
        targets: targets,
        state: state
    )
}

final class ScreenCommanderEngineTests: XCTestCase {
    /// Async replacement for `XCTAssertThrowsError` (which has no async overload).
    private func assertThrows<T>(
        _ expression: @autoclosure () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ errorHandler: (Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected an error to be thrown", file: file, line: line)
        } catch {
            errorHandler(error)
        }
    }

    func testTypeRejectsNegativeDelay() async {
        let permissions = FakePermissions()
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath("type-negative-delay").path])

        let engine = ScreenCommanderEngine(
            permissions: permissions,
            displays: NoopDisplays(),
            capturer: FakeCapturer(
                captureResult: CapturedScreenshot(
                    image: make1x1Image(),
                    displayID: 1,
                    displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                    pointPixelScale: 1
                )
            ),
            imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
            metadataStore: FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL),
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: FakeRetentionManager(),
            statePaths: state,
            fileManager: .default
        )

        await assertThrows(try await engine.type(TypeRequest(text: "bad", delayMilliseconds: -5, inputMode: .unicode)))
    }

    func testKeysRejectsSystemKeyModifiersAndAcceptsSystemPressWithoutModifiers() throws {
        let permissions = FakePermissions()
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath("keys-system").path])
        let keyboard = FakeKeyboardController()

        let engine = ScreenCommanderEngine(
            permissions: permissions,
            displays: NoopDisplays(),
            capturer: FakeCapturer(
                captureResult: CapturedScreenshot(
                    image: make1x1Image(),
                    displayID: 1,
                    displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                    pointPixelScale: 1
                )
            ),
            imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
            metadataStore: FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL),
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: keyboard,
            retention: FakeRetentionManager(),
            statePaths: state,
            fileManager: .default
        )

        XCTAssertThrowsError(try engine.keys(KeysRequest(steps: ["press:ctrl+play"])))

        let result = try engine.keys(KeysRequest(steps: ["press:mute"]))
        XCTAssertEqual(result.normalizedSteps, ["press:mute"])
        XCTAssertEqual(keyboard.systemPressed, [])
        XCTAssertEqual(keyboard.runs.count, 1)
        XCTAssertEqual(keyboard.runs[0].steps[0].normalized, "press:mute")
    }

    func testCleanupDefaultsTo24HoursWhenNil() {
        let retention = FakeRetentionManager()
        retention.result = CleanupResult(deletedCount: 1, deletedBytesApprox: 9)
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath("cleanup-default").path])

        let engine = ScreenCommanderEngine(
            permissions: FakePermissions(),
            displays: NoopDisplays(),
            capturer: FakeCapturer(
                captureResult: CapturedScreenshot(
                    image: make1x1Image(),
                    displayID: 1,
                    displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                    pointPixelScale: 1
                )
            ),
            imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
            metadataStore: FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL),
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: retention,
            statePaths: state,
            fileManager: .default,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let result = try? engine.cleanup(CleanupRequest(olderThanHours: nil))
        XCTAssertEqual(result?.deletedCount, 1)
        XCTAssertEqual(result?.deletedBytesApprox, 9)

        let call = try? XCTUnwrap(retention.calls.first)
        XCTAssertEqual(call?.olderThan, 24 * 60 * 60)
    }

    func testScreenshotWithExplicitOutputAndDisabledLastMetadataUpdate() async throws {
        let resolvedDisplay: ResolvedDisplay
        do {
            resolvedDisplay = try await Displays().resolveDisplay(identifier: "main")
        } catch {
            throw XCTSkip("Display enumeration is unavailable in this environment: \(error)")
        }

        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath("screenshot-explicit").path])
        let explicitImagePath = tempStatePath("screenshot-explicit-manual").appendingPathComponent("custom.png").path
        let explicitMetadataPath = tempStatePath("screenshot-explicit-manual").appendingPathComponent("custom.json").path

        let metadataStore = FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL)
        let imageWriter = FakeImageWriter(returnedSize: SizeD(w: 10, h: 20))
        let retention = FakeRetentionManager()

        let engine = ScreenCommanderEngine(
            permissions: FakePermissions(),
            displays: FakeDisplays(resolved: resolvedDisplay),
            capturer: FakeCapturer(
                captureResult: CapturedScreenshot(
                    image: make1x1Image(),
                    displayID: 555,
                    displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                    pointPixelScale: 1
                )
            ),
            imageWriter: imageWriter,
            metadataStore: metadataStore,
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: retention,
            statePaths: state,
            fileManager: .default,
            now: { Date(timeIntervalSince1970: 1_700_000_200) }
        )

        let result = try await engine.screenshot(
            ScreenshotRequest(
                displayIdentifier: "main",
                outputPath: explicitImagePath,
                format: .png,
                metadataPath: explicitMetadataPath,
                includeCursor: false,
                updateLastMetadata: false
            )
        )

        XCTAssertEqual(result.imagePath, explicitImagePath)
        XCTAssertEqual(result.metadataPath, explicitMetadataPath)
        XCTAssertEqual(result.lastMetadataPath, explicitMetadataPath)
        XCTAssertEqual(metadataStore.saved[0].at.path, explicitMetadataPath)
        XCTAssertEqual(metadataStore.saved[0].updateLastAt?.path, explicitMetadataPath)
        XCTAssertEqual(imageWriter.writes[0].url.path, explicitImagePath)
        XCTAssertEqual(retention.calls[0].directory, state.capturesDirectoryURL)
    }

    func testClickLoadsDefaultMetadataPathAndMapsPixels() async throws {
        let permissions = FakePermissions()
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath("click" ).path])
        let metadataStore = FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL)

        let expectedMetadata = ScreenshotMetadata(
            capturedAtISO8601: "2026-02-21T00:00:00Z",
            displayID: 123,
            displayBoundsPoints: RectD(x: 100, y: 200, w: 400, h: 300),
            imageSizePixels: SizeD(w: 800, h: 600),
            pointPixelScale: 2,
            imagePath: "/tmp/test.png"
        )
        metadataStore.seedLoad(expectedMetadata, at: state.lastMetadataURL)

        let mouse = FakeMouseController()

        let engine = ScreenCommanderEngine(
            permissions: permissions,
            displays: NoopDisplays(),
            capturer: FakeCapturer(
                captureResult: CapturedScreenshot(
                    image: make1x1Image(),
                    displayID: 123,
                    displayBoundsPoints: CGRect(x: 100, y: 200, width: 400, height: 300),
                    pointPixelScale: 2
                )
            ),
            imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
            metadataStore: metadataStore,
            coordinateMapper: CoordinateMapper(),
            mouseController: mouse,
            keyboardController: FakeKeyboardController(),
            retention: FakeRetentionManager(),
            statePaths: state,
            fileManager: .default,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let result = try await engine.click(
            ClickRequest(
                x: 200,
                y: 100,
                coordinateSpace: .pixels,
                metadataPath: nil,
                button: .left,
                doubleClick: false,
                triple: false,
                primeClick: false,
                humanLike: true,
                modifiers: []
            )
        )

        let click = try XCTUnwrap(mouse.calls.first)

        XCTAssertEqual(result.metadataPath, state.lastMetadataURL.path)
        XCTAssertEqual(click.point.x, 200)
        XCTAssertEqual(click.point.y, 250)
        XCTAssertEqual(click.destination, .global)
        XCTAssertEqual(result.resolved?.globalX, 200)
        XCTAssertEqual(result.resolved?.globalY, 250)
        XCTAssertEqual(result.deliveryMethod, .global)
        XCTAssertNil(result.requestedVia)
        XCTAssertEqual(metadataStore.loadCalls, [state.lastMetadataURL])
        XCTAssertEqual(permissions.accessibilityChecks, 1)
    }

    func testScrollCallsMouseController() async throws {
        let fixture = makeInputEngineFixture("scroll")

        let result = try await fixture.engine.scroll(
            ScrollRequest(
                x: 200,
                y: 100,
                coordinateSpace: .pixels,
                metadataPath: nil,
                dx: 4,
                dy: -3,
                unit: .pixels
            )
        )

        let call = try XCTUnwrap(fixture.mouse.scrollCalls.first)
        XCTAssertEqual(call.point.x, 200)
        XCTAssertEqual(call.point.y, 250)
        XCTAssertEqual(call.dx, 4)
        XCTAssertEqual(call.dy, -3)
        XCTAssertEqual(call.unit, .pixels)
        XCTAssertEqual(call.destination, .global)
        XCTAssertEqual(result.resolved?.globalX, 200)
        XCTAssertEqual(result.resolved?.globalY, 250)
        XCTAssertEqual(result.deliveryMethod, .global)
        XCTAssertEqual(result.dx, 4)
        XCTAssertEqual(result.dy, -3)
        XCTAssertEqual(result.unit, .pixels)
        XCTAssertEqual(fixture.permissions.accessibilityChecks, 1)
    }

    func testScrollRequiresNonzeroDelta() async {
        let fixture = makeInputEngineFixture("scroll-zero")

        await assertThrows(
            try await fixture.engine.scroll(
                ScrollRequest(
                    x: 200,
                    y: 100,
                    coordinateSpace: .pixels,
                    metadataPath: nil,
                    dx: 0,
                    dy: 0,
                    unit: .lines
                )
            )
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "invalid_arguments")
        }
        XCTAssertEqual(fixture.permissions.accessibilityChecks, 0)
        XCTAssertTrue(fixture.mouse.scrollCalls.isEmpty)
    }

    func testDragCallsMouseController() throws {
        let fixture = makeInputEngineFixture("drag")

        let result = try fixture.engine.drag(
            DragRequest(
                x1: 200,
                y1: 100,
                x2: 300,
                y2: 200,
                coordinateSpace: .pixels,
                metadataPath: nil,
                button: .right,
                steps: 8,
                durationMS: 120
            )
        )

        let call = try XCTUnwrap(fixture.mouse.dragCalls.first)
        XCTAssertEqual(call.from.x, 200)
        XCTAssertEqual(call.from.y, 250)
        XCTAssertEqual(call.to.x, 250)
        XCTAssertEqual(call.to.y, 300)
        XCTAssertEqual(call.button, .right)
        XCTAssertEqual(call.steps, 8)
        XCTAssertEqual(call.durationMS, 120)
        XCTAssertEqual(result.button, .right)
        XCTAssertEqual(result.steps, 8)
        XCTAssertEqual(result.durationMilliseconds, 120)
        XCTAssertEqual(fixture.permissions.accessibilityChecks, 1)
    }

    func testMoveCallsMouseController() throws {
        let fixture = makeInputEngineFixture("move")

        let result = try fixture.engine.move(
            MoveRequest(
                x: 200,
                y: 100,
                coordinateSpace: .pixels,
                metadataPath: nil,
                dwellMS: 0
            )
        )

        let call = try XCTUnwrap(fixture.mouse.moveCalls.first)
        XCTAssertEqual(call.point.x, 200)
        XCTAssertEqual(call.point.y, 250)
        XCTAssertEqual(result.dwellMilliseconds, 0)
        XCTAssertEqual(result.resolved.globalX, 200)
        XCTAssertEqual(result.resolved.globalY, 250)
        XCTAssertEqual(fixture.permissions.accessibilityChecks, 1)
    }

    func testClickWithModifiers() async throws {
        let fixture = makeInputEngineFixture("click-modifiers")

        let result = try await fixture.engine.click(
            ClickRequest(
                x: 200,
                y: 100,
                coordinateSpace: .pixels,
                metadataPath: nil,
                button: .middle,
                doubleClick: false,
                triple: false,
                primeClick: false,
                humanLike: true,
                modifiers: ["cmd", "shift"]
            )
        )

        let call = try XCTUnwrap(fixture.mouse.calls.first)
        XCTAssertEqual(call.button, .middle)
        XCTAssertEqual(call.modifiers, ["cmd", "shift"])
        XCTAssertEqual(result.modifiers, ["cmd", "shift"])
    }

    func testClickTriple() async throws {
        let fixture = makeInputEngineFixture("click-triple")

        let result = try await fixture.engine.click(
            ClickRequest(
                x: 200,
                y: 100,
                coordinateSpace: .pixels,
                metadataPath: nil,
                button: .left,
                doubleClick: false,
                triple: true,
                primeClick: false,
                humanLike: true,
                modifiers: []
            )
        )

        let call = try XCTUnwrap(fixture.mouse.calls.first)
        XCTAssertTrue(call.tripleClick)
        XCTAssertFalse(call.doubleClick)
        XCTAssertTrue(result.triple)
    }

    func testClickDoubleAndTripleMutuallyExclusive() async {
        let fixture = makeInputEngineFixture("click-double-triple")

        await assertThrows(
            try await fixture.engine.click(
                ClickRequest(
                    x: 200,
                    y: 100,
                    coordinateSpace: .pixels,
                    metadataPath: nil,
                    button: .left,
                    doubleClick: true,
                    triple: true,
                    primeClick: false,
                    humanLike: true,
                    modifiers: []
                )
            )
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "invalid_arguments")
        }
        XCTAssertEqual(fixture.permissions.accessibilityChecks, 0)
        XCTAssertTrue(fixture.mouse.calls.isEmpty)
    }

    func testSequenceDecodesScrollStep() throws {
        let data = Data(#"{"steps":[{"scroll":{"x":100,"y":200,"dy":-3}}]}"#.utf8)
        let file = try JSONDecoder().decode(SequenceFile.self, from: data)

        guard case .scroll(let step) = try XCTUnwrap(file.steps.first) else {
            return XCTFail("Expected scroll step.")
        }
        XCTAssertEqual(step.x, 100)
        XCTAssertEqual(step.y, 200)
        XCTAssertEqual(step.dx, nil)
        XCTAssertEqual(step.dy, -3)
    }

    func testSequenceDecodesHorizontalOnlyScrollStep() throws {
        let data = Data(#"{"steps":[{"scroll":{"x":100,"y":200,"dx":10}}]}"#.utf8)
        let file = try JSONDecoder().decode(SequenceFile.self, from: data)

        guard case .scroll(let step) = try XCTUnwrap(file.steps.first) else {
            return XCTFail("Expected scroll step.")
        }
        XCTAssertEqual(step.dx, 10)
        XCTAssertEqual(step.dy, nil)
    }

    func testScrollCommandAllowsHorizontalOnlyDelta() throws {
        let command = try ScrollCommand.parse(["100", "200", "--dx", "10"])

        XCTAssertEqual(command.dx, 10)
        XCTAssertEqual(command.dy, 0)
    }

    func testSequenceDecodesDragStep() throws {
        let data = Data(#"{"steps":[{"drag":{"x1":10,"y1":20,"x2":30,"y2":40,"button":"middle","steps":5,"durationMS":90}}]}"#.utf8)
        let file = try JSONDecoder().decode(SequenceFile.self, from: data)

        guard case .drag(let step) = try XCTUnwrap(file.steps.first) else {
            return XCTFail("Expected drag step.")
        }
        XCTAssertEqual(step.x1, 10)
        XCTAssertEqual(step.y1, 20)
        XCTAssertEqual(step.x2, 30)
        XCTAssertEqual(step.y2, 40)
        XCTAssertEqual(step.button, .middle)
        XCTAssertEqual(step.steps, 5)
        XCTAssertEqual(step.durationMS, 90)
    }

    func testSequenceDecodesMoveStep() throws {
        let data = Data(#"{"steps":[{"move":{"x":100,"y":200,"dwellMS":25}}]}"#.utf8)
        let file = try JSONDecoder().decode(SequenceFile.self, from: data)

        guard case .move(let step) = try XCTUnwrap(file.steps.first) else {
            return XCTFail("Expected move step.")
        }
        XCTAssertEqual(step.x, 100)
        XCTAssertEqual(step.y, 200)
        XCTAssertEqual(step.dwellMS, 25)
    }

    func testSequenceDecodesSleepStep() throws {
        let data = Data(#"{"steps":[{"sleep":{"ms":50}}]}"#.utf8)
        let file = try JSONDecoder().decode(SequenceFile.self, from: data)

        guard case .sleep(let step) = try XCTUnwrap(file.steps.first) else {
            return XCTFail("Expected sleep step.")
        }
        XCTAssertEqual(step.ms, 50)
    }

    func testTypeAndKeysFlowThroughKeyboardController() async throws {
        let permissions = FakePermissions()
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath("typing" ).path])
        let metadataStore = FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL)
        let keyboard = FakeKeyboardController()

        let engine = ScreenCommanderEngine(
            permissions: permissions,
            displays: NoopDisplays(),
            capturer: FakeCapturer(
                captureResult: CapturedScreenshot(
                    image: make1x1Image(),
                    displayID: 1,
                    displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                    pointPixelScale: 1
                )
            ),
            imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
            metadataStore: metadataStore,
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: keyboard,
            retention: FakeRetentionManager(),
            statePaths: state,
            fileManager: .default
        )

        _ = try await engine.type(TypeRequest(text: "hello", delayMilliseconds: 25, inputMode: .unicode))
        _ = try await engine.type(TypeRequest(text: "paste", delayMilliseconds: nil, inputMode: .paste))
        _ = try engine.key(KeyRequest(chord: "ctrl+shift+tab"))
        _ = try engine.keys(KeysRequest(steps: ["down:cmd", "press:tab", "sleep:10", "up:cmd"]))

        XCTAssertEqual(keyboard.typed.count, 1)
        XCTAssertEqual(keyboard.typed[0].text, "hello")
        XCTAssertEqual(keyboard.typed[0].delayMilliseconds, 25)
        XCTAssertEqual(keyboard.pasted, ["paste"])
        XCTAssertEqual(keyboard.pressed.count, 1)
        XCTAssertEqual(keyboard.pressed[0].normalized, "shift+ctrl+tab")

        let sequence = try XCTUnwrap(keyboard.runs.first)
        XCTAssertEqual(sequence.steps.count, 4)
        XCTAssertEqual(sequence.steps[0].normalized, "down:cmd")
        XCTAssertEqual(sequence.steps[1].normalized, "press:tab")
        XCTAssertEqual(sequence.steps[2].normalized, "sleep:10")
        XCTAssertEqual(sequence.steps[3].normalized, "up:cmd")
        XCTAssertEqual(permissions.accessibilityChecks, 4)
    }

    func testKeySupportsSpecialAliasesThroughEngine() throws {
        let permissions = FakePermissions()
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath("special-alias" ).path])
        let keyboard = FakeKeyboardController()

        let engine = ScreenCommanderEngine(
            permissions: permissions,
            displays: NoopDisplays(),
            capturer: FakeCapturer(
                captureResult: CapturedScreenshot(
                    image: make1x1Image(),
                    displayID: 1,
                    displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                    pointPixelScale: 1
                )
            ),
            imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
            metadataStore: FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL),
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: keyboard,
            retention: FakeRetentionManager(),
            statePaths: state,
            fileManager: .default
        )

        let spotlightResult = try engine.key(KeyRequest(chord: "spotlight"))
        let raycastResult = try engine.key(KeyRequest(chord: "raycast"))
        let launchpadResult = try engine.key(KeyRequest(chord: "launchpad"))
        let missionControlResult = try engine.key(KeyRequest(chord: "missioncontrol"))

        XCTAssertEqual(spotlightResult.normalizedChord, "cmd+space")
        XCTAssertEqual(raycastResult.normalizedChord, "cmd+space")
        XCTAssertEqual(launchpadResult.normalizedChord, "launchpad")
        XCTAssertEqual(missionControlResult.normalizedChord, "missioncontrol")
        XCTAssertEqual(keyboard.pressed.count, 4)
        XCTAssertEqual(permissions.accessibilityChecks, 4)
    }

    func testCleanupUsesRetentionManager() throws {
        let permissions = FakePermissions()
        let retention = FakeRetentionManager()
        retention.result = CleanupResult(deletedCount: 3, deletedBytesApprox: 128)

        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath("cleanup" ).path])
        let engine = ScreenCommanderEngine(
            permissions: permissions,
            displays: NoopDisplays(),
            capturer: FakeCapturer(
                captureResult: CapturedScreenshot(
                    image: make1x1Image(),
                    displayID: 1,
                    displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                    pointPixelScale: 1
                )
            ),
            imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
            metadataStore: FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL),
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: retention,
            statePaths: state,
            fileManager: .default,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let result = try engine.cleanup(CleanupRequest(olderThanHours: 6))
        XCTAssertEqual(result.deletedCount, 3)
        XCTAssertEqual(result.deletedBytesApprox, 128)

        let call = try XCTUnwrap(retention.calls.first)
        XCTAssertEqual(call.directory.standardizedFileURL.path, state.capturesDirectoryURL.standardizedFileURL.path)
        XCTAssertEqual(call.olderThan, 6 * 60 * 60)
    }

    func testCleanupRejectsNegativeAges() {
        let retention = FakeRetentionManager()
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath("cleanup-negative" ).path])
        let engine = ScreenCommanderEngine(
            permissions: FakePermissions(),
            displays: NoopDisplays(),
            capturer: FakeCapturer(
                captureResult: CapturedScreenshot(
                    image: make1x1Image(),
                    displayID: 1,
                    displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                    pointPixelScale: 1
                )
            ),
            imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
            metadataStore: FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL),
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: retention,
            statePaths: state,
            fileManager: .default
        )

        XCTAssertThrowsError(try engine.cleanup(CleanupRequest(olderThanHours: -1)))
    }

    func testScreenshotUsesManagedCaptureDirectoryForDefaultOutput() async throws {
        let baseStatePath = tempStatePath("screenshot-default").path
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": baseStatePath])

        let resolvedDisplay: ResolvedDisplay
        do {
            resolvedDisplay = try await Displays().resolveDisplay(identifier: "main")
        } catch {
            throw XCTSkip("Display enumeration is unavailable in this environment: \(error)")
        }

        let fakeDisplay = FakeDisplays(resolved: resolvedDisplay)
        let retention = FakeRetentionManager()
        let metadataStore = FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL)
        let imageWriter = FakeImageWriter(returnedSize: SizeD(w: 1920, h: 1080))
        let capturer = FakeCapturer(
            captureResult: CapturedScreenshot(
                image: make1x1Image(),
                displayID: 1,
                displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                pointPixelScale: 1
            )
        )

        let engine = ScreenCommanderEngine(
            permissions: FakePermissions(),
            displays: fakeDisplay,
            capturer: capturer,
            imageWriter: imageWriter,
            metadataStore: metadataStore,
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: retention,
            statePaths: state,
            fileManager: .default,
            now: { Date(timeIntervalSince1970: 1_700_000_100) }
        )

        _ = try await engine.screenshot(
            ScreenshotRequest(
                displayIdentifier: "main",
                outputPath: nil,
                format: .png,
                metadataPath: nil,
                includeCursor: false,
                updateLastMetadata: true
            )
        )

        XCTAssertEqual(capturer.calls, 1)
        XCTAssertEqual(imageWriter.writes.count, 1)
        let writtenURL = imageWriter.writes[0].url
        XCTAssertEqual(writtenURL.deletingLastPathComponent().path, state.capturesDirectoryURL.path)
        XCTAssertEqual(writtenURL.pathExtension, "png")
        XCTAssertEqual(metadataStore.saved.count, 1)
        XCTAssertEqual(metadataStore.saved[0].at.path, writtenURL.deletingPathExtension().appendingPathExtension("json").path)
        XCTAssertEqual(retention.calls.count, 1)
        XCTAssertEqual(retention.calls[0].olderThan, 24 * 60 * 60)
        XCTAssertTrue(metadataStore.saved[0].updateLastAt == state.lastMetadataURL)
    }

    // MARK: - WP2 tests

    func testWindowsListsAllWindows() async throws {
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath("wp2-windows-all").path])
        let resolver = FakeTargetResolver()
        resolver.windowList = [
            WindowInfo(windowID: 1, title: "Main Window", appName: "Safari", pid: 100, boundsPoints: RectD(x: 0, y: 0, w: 1280, h: 800), isOnScreen: true, layer: 0),
            WindowInfo(windowID: 2, title: "Preferences", appName: "Safari", pid: 100, boundsPoints: RectD(x: 100, y: 100, w: 600, h: 400), isOnScreen: true, layer: 0),
            WindowInfo(windowID: 3, title: "Hidden", appName: "Safari", pid: 100, boundsPoints: RectD(x: -10000, y: -10000, w: 600, h: 400), isOnScreen: false, layer: 0)
        ]

        let engine = ScreenCommanderEngine(
            permissions: FakePermissions(),
            displays: NoopDisplays(),
            capturer: FakeCapturer(captureResult: CapturedScreenshot(image: make1x1Image(), displayID: 1, displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1), pointPixelScale: 1)),
            imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
            metadataStore: FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL),
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: FakeRetentionManager(),
            targets: resolver,
            statePaths: state
        )

        let result = try await engine.windows(WindowsRequest(appIdentifier: nil))
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertEqual(result.windows[0].windowID, 1)
        XCTAssertEqual(result.windows[1].windowID, 2)
        XCTAssertFalse(result.windows.contains { !$0.isOnScreen })
    }

    func testWindowsFiltersByApp() async throws {
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath("wp2-windows-filtered").path])
        let resolver = FakeTargetResolver()
        resolver.apps["Safari"] = ResolvedApp(pid: 100, name: "Safari", bundleID: "com.apple.safari")
        resolver.windowList = [
            WindowInfo(windowID: 1, title: "Safari Win", appName: "Safari", pid: 100, boundsPoints: RectD(x: 0, y: 0, w: 1280, h: 800), isOnScreen: true, layer: 0),
            WindowInfo(windowID: 2, title: "Finder Win", appName: "Finder", pid: 200, boundsPoints: RectD(x: 0, y: 0, w: 800, h: 600), isOnScreen: true, layer: 0)
        ]

        let engine = ScreenCommanderEngine(
            permissions: FakePermissions(),
            displays: NoopDisplays(),
            capturer: FakeCapturer(captureResult: CapturedScreenshot(image: make1x1Image(), displayID: 1, displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1), pointPixelScale: 1)),
            imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
            metadataStore: FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL),
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: FakeRetentionManager(),
            targets: resolver,
            statePaths: state
        )

        let result = try await engine.windows(WindowsRequest(appIdentifier: "Safari"))
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows[0].appName, "Safari")
    }

    func testCoordinateMapperWindowBoundsOverridesDisplayBounds() throws {
        // Window at (500, 300) with size 800x600, scale 2.0
        let windowBounds = RectD(x: 500, y: 300, w: 800, h: 600)
        let metadata = ScreenshotMetadata(
            capturedAtISO8601: "2024-01-01T00:00:00.000Z",
            displayID: 0,
            displayBoundsPoints: RectD(x: 0, y: 0, w: 2560, h: 1600),
            imageSizePixels: SizeD(w: 1600, h: 1200),
            pointPixelScale: 2.0,
            imagePath: "/tmp/test.png",
            windowID: 42,
            windowBoundsPoints: windowBounds
        )

        let mapper = CoordinateMapper()
        // Pixel (200, 100) -> points (100, 50) -> global (500+100, 300+50) = (600, 350)
        let resolved = try mapper.map(x: 200, y: 100, space: .pixels, metadata: metadata)
        XCTAssertEqual(resolved.globalX, 600.0)
        XCTAssertEqual(resolved.globalY, 350.0)
    }

    func testCoordinateMapperWithoutWindowBoundsUsesDisplayBounds() throws {
        let metadata = ScreenshotMetadata(
            capturedAtISO8601: "2024-01-01T00:00:00.000Z",
            displayID: 1,
            displayBoundsPoints: RectD(x: 0, y: 0, w: 1280, h: 800),
            imageSizePixels: SizeD(w: 2560, h: 1600),
            pointPixelScale: 2.0,
            imagePath: "/tmp/test.png"
        )

        let mapper = CoordinateMapper()
        // Pixel (200, 100) -> points (100, 50) -> global (0+100, 0+50) = (100, 50)
        let resolved = try mapper.map(x: 200, y: 100, space: .pixels, metadata: metadata)
        XCTAssertEqual(resolved.globalX, 100.0)
        XCTAssertEqual(resolved.globalY, 50.0)
    }

    func testMetadataBackwardCompatibilityWithoutWindowFields() throws {
        // Old sidecar JSON without windowID/windowBoundsPoints should still decode
        let json = """
        {
            "capturedAtISO8601": "2024-01-01T00:00:00.000Z",
            "displayID": 1,
            "displayBoundsPoints": {"x": 0, "y": 0, "w": 1280, "h": 800},
            "imageSizePixels": {"w": 2560, "h": 1600},
            "pointPixelScale": 2.0,
            "imagePath": "/tmp/test.png"
        }
        """.data(using: .utf8)!

        let metadata = try JSONDecoder().decode(ScreenshotMetadata.self, from: json)
        XCTAssertNil(metadata.windowID)
        XCTAssertNil(metadata.windowBoundsPoints)
        XCTAssertEqual(metadata.displayID, 1)
    }

    private func makeWindowEngineFixture(
        stateName: String,
        resolver: FakeTargetResolver,
        captured: CapturedScreenshot,
        frontmostApp: @escaping () -> ResolvedApp? = { nil },
        activateApp: @escaping (ResolvedApp) throws -> Void = { _ in }
    ) -> (engine: ScreenCommanderEngine, metadataStore: FakeMetadataStore, imageWriter: FakeImageWriter, state: StatePaths) {
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath(stateName).path])
        let metadataStore = FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL)
        let imageWriter = FakeImageWriter(returnedSize: SizeD(w: 1600, h: 1200))

        let engine = ScreenCommanderEngine(
            permissions: FakePermissions(),
            displays: NoopDisplays(),
            capturer: FakeCapturer(captureResult: captured),
            imageWriter: imageWriter,
            metadataStore: metadataStore,
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: FakeRetentionManager(),
            targets: resolver,
            frontmostApp: frontmostApp,
            activateApp: activateApp,
            statePaths: state,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        return (engine, metadataStore, imageWriter, state)
    }

    func testScreenshotWindowCapturePersistsWindowMetadata() async throws {
        let windowBounds = RectD(x: 500, y: 300, w: 800, h: 600)
        let resolver = FakeTargetResolver()
        resolver.windowByIdentifier["Safari"] = WindowInfo(
            windowID: 42,
            title: "Apple",
            appName: "Safari",
            pid: 100,
            boundsPoints: windowBounds,
            isOnScreen: true,
            layer: 0
        )

        let (engine, metadataStore, _, state) = makeWindowEngineFixture(
            stateName: "wp2-window-shot",
            resolver: resolver,
            captured: CapturedScreenshot(
                image: make1x1Image(),
                displayID: 7,
                displayBoundsPoints: CGRect(x: 0, y: 0, width: 2560, height: 1600),
                pointPixelScale: 2
            )
        )

        let result = try await engine.screenshot(
            ScreenshotRequest(
                displayIdentifier: "main",
                outputPath: nil,
                format: .png,
                metadataPath: nil,
                includeCursor: false,
                updateLastMetadata: true,
                windowIdentifier: "Safari"
            )
        )

        XCTAssertEqual(resolver.resolveWindowCalls, ["Safari"])

        // The persisted sidecar carries the resolved window bounds — the exact rect
        // CoordinateMapper later uses to map window-relative pixels to global points.
        XCTAssertEqual(result.metadata.windowID, 42)
        XCTAssertEqual(result.metadata.windowBoundsPoints, windowBounds)
        XCTAssertEqual(result.metadata.displayID, 7)
        XCTAssertEqual(result.metadata.displayBoundsPoints, RectD(x: 0, y: 0, w: 2560, h: 1600))
        XCTAssertEqual(result.metadata.pointPixelScale, 2)

        XCTAssertEqual(metadataStore.saved.count, 1)
        XCTAssertEqual(metadataStore.saved[0].metadata.windowID, 42)
        XCTAssertEqual(metadataStore.saved[0].metadata.windowBoundsPoints, windowBounds)
        XCTAssertEqual(metadataStore.saved[0].updateLastAt, state.lastMetadataURL)

        // The in-memory capture rides along for frame diffing (no PNG re-decode).
        XCTAssertNotNil(result.image)
    }

    func testScreenshotWindowMetadataRoundTripsThroughJSON() async throws {
        let resolver = FakeTargetResolver()
        resolver.windowByIdentifier["77"] = WindowInfo(
            windowID: 77,
            title: "Doc",
            appName: "TextEdit",
            pid: 33,
            boundsPoints: RectD(x: 120, y: 90, w: 640, h: 480),
            isOnScreen: true,
            layer: 0
        )

        let (engine, _, _, _) = makeWindowEngineFixture(
            stateName: "wp2-window-roundtrip",
            resolver: resolver,
            captured: CapturedScreenshot(
                image: make1x1Image(),
                displayID: 1,
                displayBoundsPoints: CGRect(x: 0, y: 0, width: 1440, height: 900),
                pointPixelScale: 2
            )
        )

        let result = try await engine.screenshot(
            ScreenshotRequest(
                displayIdentifier: "main",
                outputPath: nil,
                format: .png,
                metadataPath: nil,
                includeCursor: false,
                updateLastMetadata: true,
                windowIdentifier: "77"
            )
        )

        let encoded = try JSONEncoder().encode(result.metadata)
        let decoded = try JSONDecoder().decode(ScreenshotMetadata.self, from: encoded)

        XCTAssertEqual(decoded.windowID, 77)
        XCTAssertEqual(decoded.windowBoundsPoints, RectD(x: 120, y: 90, w: 640, h: 480))
        XCTAssertEqual(decoded.displayID, 1)
        XCTAssertEqual(decoded.displayBoundsPoints, RectD(x: 0, y: 0, w: 1440, h: 900))
        XCTAssertEqual(decoded.pointPixelScale, 2)
    }

    func testScreenshotWindowNotFoundPropagates() async {
        let resolver = FakeTargetResolver()

        let (engine, _, _, _) = makeWindowEngineFixture(
            stateName: "wp2-window-missing",
            resolver: resolver,
            captured: CapturedScreenshot(
                image: make1x1Image(),
                displayID: 1,
                displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                pointPixelScale: 1
            )
        )

        do {
            _ = try await engine.screenshot(
                ScreenshotRequest(
                    displayIdentifier: "main",
                    outputPath: nil,
                    format: .png,
                    metadataPath: nil,
                    includeCursor: false,
                    updateLastMetadata: true,
                    windowIdentifier: "Nope"
                )
            )
            XCTFail("Expected window_not_found")
        } catch let error as ScreenCommanderError {
            XCTAssertEqual(error.stableCode, "window_not_found")
            XCTAssertEqual(error.exitCode, 80)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - focus

    func testFocusActivatesResolvedAppAndReportsPriorApp() async throws {
        let safari = ResolvedApp(pid: 100, name: "Safari", bundleID: "com.apple.Safari")
        let finder = ResolvedApp(pid: 200, name: "Finder", bundleID: "com.apple.finder")
        let resolver = FakeTargetResolver()
        resolver.apps["Safari"] = safari

        var activated: [ResolvedApp] = []
        let (engine, _, _, _) = makeWindowEngineFixture(
            stateName: "wp2-focus",
            resolver: resolver,
            captured: CapturedScreenshot(
                image: make1x1Image(),
                displayID: 1,
                displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                pointPixelScale: 1
            ),
            frontmostApp: { finder },
            activateApp: { activated.append($0) }
        )

        let result = try await engine.focus(FocusRequest(appIdentifier: "Safari"))

        XCTAssertEqual(result.app, safari)
        XCTAssertEqual(result.priorApp, finder)
        XCTAssertEqual(activated, [safari])
    }

    func testFocusReportsNilPriorAppWhenNoneIsFrontmost() async throws {
        let safari = ResolvedApp(pid: 100, name: "Safari", bundleID: "com.apple.Safari")
        let resolver = FakeTargetResolver()
        resolver.apps["Safari"] = safari

        let (engine, _, _, _) = makeWindowEngineFixture(
            stateName: "wp2-focus-no-prior",
            resolver: resolver,
            captured: CapturedScreenshot(
                image: make1x1Image(),
                displayID: 1,
                displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                pointPixelScale: 1
            ),
            frontmostApp: { nil }
        )

        let result = try await engine.focus(FocusRequest(appIdentifier: "Safari"))

        XCTAssertEqual(result.app, safari)
        XCTAssertNil(result.priorApp)
    }

    func testFocusThrowsAppNotFoundWhenAppIsGoneAtActivation() async {
        let safari = ResolvedApp(pid: 100, name: "Safari", bundleID: "com.apple.Safari")
        let resolver = FakeTargetResolver()
        resolver.apps["Safari"] = safari

        let (engine, _, _, _) = makeWindowEngineFixture(
            stateName: "wp2-focus-gone",
            resolver: resolver,
            captured: CapturedScreenshot(
                image: make1x1Image(),
                displayID: 1,
                displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                pointPixelScale: 1
            ),
            activateApp: { app in
                throw ScreenCommanderError.appNotFound("App with PID \(app.pid) is no longer running.")
            }
        )

        do {
            _ = try await engine.focus(FocusRequest(appIdentifier: "Safari"))
            XCTFail("Expected app_not_found")
        } catch let error as ScreenCommanderError {
            XCTAssertEqual(error.stableCode, "app_not_found")
            XCTAssertEqual(error.exitCode, 81)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testFocusPropagatesAppNotFoundFromResolver() async {
        let (engine, _, _, _) = makeWindowEngineFixture(
            stateName: "wp2-focus-unresolved",
            resolver: FakeTargetResolver(),
            captured: CapturedScreenshot(
                image: make1x1Image(),
                displayID: 1,
                displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                pointPixelScale: 1
            ),
            activateApp: { _ in XCTFail("Activation must not run when resolution fails") }
        )

        do {
            _ = try await engine.focus(FocusRequest(appIdentifier: "Ghost"))
            XCTFail("Expected app_not_found")
        } catch let error as ScreenCommanderError {
            XCTAssertEqual(error.stableCode, "app_not_found")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - sleep helper

    func testSleepTimerReturnsImmediatelyForNonPositiveValues() {
        let start = Date()
        SleepTimer.sleep(milliseconds: 0)
        SleepTimer.sleep(milliseconds: -5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testSleepTimerChunkFitsInUseconds() {
        // Guards the overflow fix: a full chunk converted to microseconds must fit
        // in useconds_t (UInt32), so huge sleep/dwell values can never trap.
        XCTAssertLessThanOrEqual(SleepTimer.maxChunkMilliseconds * 1_000, UInt64(UInt32.max))
    }

    // MARK: - elements (AX read core)

    private func makeElementsEngine(
        stateName: String,
        permissions: FakePermissions = FakePermissions(),
        reader: FakeAccessibilityReader,
        targets: FakeTargets = FakeTargets(),
        frontmostApp: @escaping () -> ResolvedApp? = { nil }
    ) -> (engine: ScreenCommanderEngine, metadataStore: FakeMetadataStore, state: StatePaths) {
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath(stateName).path])
        let metadataStore = FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL)

        let engine = ScreenCommanderEngine(
            permissions: permissions,
            displays: NoopDisplays(),
            capturer: FakeCapturer(
                captureResult: CapturedScreenshot(
                    image: make1x1Image(),
                    displayID: 1,
                    displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                    pointPixelScale: 1
                )
            ),
            imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
            metadataStore: metadataStore,
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: FakeRetentionManager(),
            accessibilityReader: reader,
            targets: targets,
            frontmostApp: frontmostApp,
            statePaths: state,
            fileManager: .default
        )
        return (engine, metadataStore, state)
    }

    func testElementsDefaultsToFrontmostAppAndChecksAccessibility() async throws {
        let permissions = FakePermissions()
        let reader = FakeAccessibilityReader()
        reader.treeResult = AXTreeResult(
            axPrimed: true,
            truncated: true,
            elements: [AXElementRecord(id: "0", role: "AXWindow", title: "Doc")]
        )
        let frontmost = ResolvedApp(pid: 42, name: "TextEdit", bundleID: "com.apple.TextEdit")

        let (engine, _, _) = makeElementsEngine(
            stateName: "elements-frontmost",
            permissions: permissions,
            reader: reader,
            frontmostApp: { frontmost }
        )

        let result = try await engine.elements(ElementsRequest())

        XCTAssertEqual(permissions.accessibilityChecks, 1)
        XCTAssertEqual(reader.treeCalls.count, 1)
        XCTAssertEqual(reader.treeCalls[0].app, frontmost)
        XCTAssertEqual(result.app, frontmost)
        XCTAssertTrue(result.axPrimed)
        XCTAssertTrue(result.truncated)
        XCTAssertNil(result.metadataPath)
        XCTAssertEqual(result.elements.map(\.id), ["0"])
        XCTAssertNil(result.text)
    }

    func testElementsResolvesAppIdentifierThroughTargetsAndForwardsOptions() async throws {
        let reader = FakeAccessibilityReader()
        reader.treeResult = AXTreeResult(
            axPrimed: false,
            truncated: false,
            elements: [AXElementRecord(id: "0", role: "AXWindow")]
        )
        let targets = FakeTargets()
        let safari = ResolvedApp(pid: 7, name: "Safari", bundleID: "com.apple.Safari")
        targets.apps["Safari"] = safari

        let (engine, _, _) = makeElementsEngine(
            stateName: "elements-app",
            reader: reader,
            targets: targets,
            frontmostApp: { ResolvedApp(pid: 1, name: "WrongApp", bundleID: nil) }
        )

        let request = ElementsRequest(
            appIdentifier: "Safari",
            windowID: 900,
            maxDepth: 5,
            maxElements: 10,
            roles: ["AXButton"],
            visibleOnly: true,
            maxValueLength: 32
        )
        let result = try await engine.elements(request)

        XCTAssertEqual(targets.resolveCalls, ["Safari"])
        XCTAssertEqual(result.app, safari)
        XCTAssertEqual(result.windowID, 900)

        let options = try XCTUnwrap(reader.treeCalls.first?.options)
        XCTAssertEqual(options.windowID, 900)
        XCTAssertEqual(options.maxDepth, 5)
        XCTAssertEqual(options.maxElements, 10)
        XCTAssertEqual(options.roles, ["AXButton"])
        XCTAssertTrue(options.visibleOnly)
        XCTAssertEqual(options.maxValueLength, 32)
    }

    func testElementsMapsBoundsPixelsFromLastScreenshotMetadata() async throws {
        let reader = FakeAccessibilityReader()
        reader.treeResult = AXTreeResult(
            axPrimed: false,
            truncated: false,
            elements: [
                AXElementRecord(id: "0", role: "AXWindow", boundsPoints: RectD(x: 150, y: 250, w: 50, h: 40)),
                AXElementRecord(id: "0.0", role: "AXButton", boundsPoints: RectD(x: 600, y: 600, w: 10, h: 10)),
                AXElementRecord(id: "0.1", role: "AXGroup")
            ]
        )

        let (engine, metadataStore, state) = makeElementsEngine(
            stateName: "elements-pixels",
            reader: reader,
            frontmostApp: { ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil) }
        )

        // Secondary-display-style nonzero origin, scale 2.0 — mirrors CoordinateMapperTests.
        metadataStore.seedLoad(
            ScreenshotMetadata(
                capturedAtISO8601: "2026-07-06T00:00:00Z",
                displayID: 9,
                displayBoundsPoints: RectD(x: 100, y: 200, w: 400, h: 300),
                imageSizePixels: SizeD(w: 800, h: 600),
                pointPixelScale: 2,
                imagePath: "/tmp/test.png"
            ),
            at: state.lastMetadataURL
        )

        let result = try await engine.elements(ElementsRequest())

        XCTAssertEqual(result.metadataPath, state.lastMetadataURL.path)
        XCTAssertEqual(result.elements[0].boundsPixels, RectD(x: 100, y: 100, w: 100, h: 80))
        XCTAssertNil(result.elements[1].boundsPixels, "Element outside metadata bounds must have nil pixel bounds")
        XCTAssertNil(result.elements[2].boundsPixels, "Element without a frame must have nil pixel bounds")
    }

    func testElementsOmitsPixelBoundsAndMetadataPathWithoutLastScreenshot() async throws {
        let reader = FakeAccessibilityReader()
        reader.treeResult = AXTreeResult(
            axPrimed: false,
            truncated: false,
            elements: [AXElementRecord(id: "0", role: "AXWindow", boundsPoints: RectD(x: 0, y: 0, w: 10, h: 10))]
        )

        let (engine, _, _) = makeElementsEngine(
            stateName: "elements-no-metadata",
            reader: reader,
            frontmostApp: { ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil) }
        )

        let result = try await engine.elements(ElementsRequest())

        XCTAssertNil(result.metadataPath)
        XCTAssertNil(result.elements[0].boundsPixels)
        XCTAssertNotNil(result.elements[0].boundsPoints)
    }

    func testElementsTextModePopulatesRenderedText() async throws {
        let reader = FakeAccessibilityReader()
        reader.treeResult = AXTreeResult(
            axPrimed: false,
            truncated: false,
            elements: [
                AXElementRecord(id: "0", role: "AXWindow", title: "Untitled"),
                AXElementRecord(id: "0.0", role: "AXGroup"),
                AXElementRecord(id: "0.0.0", role: "AXTextArea", value: "hello")
            ]
        )

        let (engine, _, _) = makeElementsEngine(
            stateName: "elements-text",
            reader: reader,
            frontmostApp: { ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil) }
        )

        let result = try await engine.elements(ElementsRequest(includeText: true))

        XCTAssertEqual(result.text, "AXWindow \"Untitled\"\n    AXTextArea: hello")
    }

    func testElementsRejectsInvalidLimitsAndConflictingWindowFlags() async {
        let reader = FakeAccessibilityReader()
        let (engine, _, _) = makeElementsEngine(
            stateName: "elements-invalid",
            reader: reader,
            frontmostApp: { ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil) }
        )

        for request in [
            ElementsRequest(maxDepth: 0),
            ElementsRequest(maxElements: 0),
            ElementsRequest(maxValueLength: -1),
            ElementsRequest(windowID: 1, allWindows: true)
        ] {
            do {
                _ = try await engine.elements(request)
                XCTFail("Expected invalid_arguments for request \(request)")
            } catch let error as ScreenCommanderError {
                XCTAssertEqual(error.stableCode, "invalid_arguments")
            } catch {
                XCTFail("Unexpected error type: \(error)")
            }
        }
        XCTAssertTrue(reader.treeCalls.isEmpty)
    }

    func testElementsFailsWithoutFrontmostAppOrIdentifier() async {
        let reader = FakeAccessibilityReader()
        let (engine, _, _) = makeElementsEngine(
            stateName: "elements-no-frontmost",
            reader: reader,
            frontmostApp: { nil }
        )

        do {
            _ = try await engine.elements(ElementsRequest())
            XCTFail("Expected invalid_arguments")
        } catch let error as ScreenCommanderError {
            XCTAssertEqual(error.stableCode, "invalid_arguments")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testElementsPropagatesAxTreeUnavailable() async {
        let reader = FakeAccessibilityReader()
        reader.treeError = ScreenCommanderError.axTreeUnavailable("no tree")

        let (engine, _, _) = makeElementsEngine(
            stateName: "elements-unavailable",
            reader: reader,
            frontmostApp: { ResolvedApp(pid: 42, name: "Electron", bundleID: nil) }
        )

        do {
            _ = try await engine.elements(ElementsRequest())
            XCTFail("Expected ax_tree_unavailable")
        } catch let error as ScreenCommanderError {
            XCTAssertEqual(error.stableCode, "ax_tree_unavailable")
            XCTAssertEqual(error.exitCode, 71)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testElementsDeniedAccessibilityStopsBeforeReadingTree() async {
        let permissions = FakePermissions()
        permissions.allowAccessibility = false
        let reader = FakeAccessibilityReader()

        let (engine, _, _) = makeElementsEngine(
            stateName: "elements-denied",
            permissions: permissions,
            reader: reader,
            frontmostApp: { ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil) }
        )

        do {
            _ = try await engine.elements(ElementsRequest())
            XCTFail("Expected permission error")
        } catch let error as ScreenCommanderError {
            XCTAssertEqual(error.stableCode, "permission_denied_accessibility")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertTrue(reader.treeCalls.isEmpty)
    }

    // MARK: - WP5: pointer-free input (element clicks, --via, tier fallback)

    private static let targetApp = ResolvedApp(pid: 77, name: "TargetApp", bundleID: "com.example.target")

    private func buttonRecord(
        id: String = "0.1",
        role: String = "AXButton",
        title: String? = "Save",
        actions: [String] = ["AXPress"],
        enabled: Bool = true,
        bounds: RectD? = RectD(x: 100, y: 200, w: 40, h: 20)
    ) -> AXElementRecord {
        AXElementRecord(id: id, role: role, title: title, enabled: enabled, actions: actions, boundsPoints: bounds)
    }

    private func makeElementClickFixture(_ name: String, records: [AXElementRecord]) -> InputEngineFixture {
        let fixture = makeInputEngineFixture(name, frontmostApp: Self.targetApp)
        fixture.reader.treeResult = AXTreeResult(axPrimed: false, truncated: false, elements: records)
        return fixture
    }

    private func elementClickRequest(
        element: String? = "Save",
        elementID: String? = nil,
        role: String? = nil,
        app: String? = nil,
        button: MouseButtonChoice = .left,
        double: Bool = false,
        via: InputDeliveryMethod? = nil,
        noCursor: Bool = false,
        strict: Bool = false
    ) -> ClickRequest {
        ClickRequest(
            x: nil,
            y: nil,
            coordinateSpace: .pixels,
            metadataPath: nil,
            button: button,
            doubleClick: double,
            triple: false,
            primeClick: false,
            humanLike: false,
            modifiers: [],
            element: element,
            elementID: elementID,
            role: role,
            appIdentifier: app,
            via: via,
            noCursor: noCursor,
            strict: strict
        )
    }

    func testElementClickPrefersAXTier() async throws {
        let fixture = makeElementClickFixture("wp5-ax-tier", records: [buttonRecord()])

        let result = try await fixture.engine.click(elementClickRequest())

        XCTAssertEqual(fixture.axActions.performedActions, ["AXPress"])
        XCTAssertTrue(fixture.mouse.calls.isEmpty, "AX delivery must not synthesize mouse events")
        XCTAssertEqual(result.deliveryMethod, .ax)
        XCTAssertNil(result.requestedVia)
        XCTAssertEqual(result.element?.id, "0.1")
        XCTAssertNil(result.resolved)
        XCTAssertNil(result.metadataPath)
        XCTAssertEqual(fixture.reader.resolveCalls.map(\.id), ["0.1"])
        XCTAssertEqual(fixture.reader.resolveCalls.first?.app, Self.targetApp)
        XCTAssertEqual(fixture.permissions.accessibilityChecks, 1)
    }

    func testElementClickFallsBackToPidWhenAXUnsupported() async throws {
        let fixture = makeElementClickFixture("wp5-pid-fallback", records: [buttonRecord(actions: [])])

        let result = try await fixture.engine.click(elementClickRequest())

        XCTAssertTrue(fixture.axActions.performedActions.isEmpty)
        let click = try XCTUnwrap(fixture.mouse.calls.first)
        XCTAssertEqual(click.destination, .pid(77))
        XCTAssertEqual(click.point, CGPoint(x: 120, y: 210), "pid clicks land on the element's center")
        XCTAssertEqual(result.deliveryMethod, .pid)
        XCTAssertEqual(result.resolved?.globalX, 120)
        XCTAssertEqual(result.resolved?.globalY, 210)
        XCTAssertEqual(result.resolved?.space, .points)
    }

    func testElementClickFallsBackToGlobalWhenPidFails() async throws {
        let fixture = makeElementClickFixture("wp5-global-fallback", records: [buttonRecord(actions: [])])
        fixture.mouse.pidClickError = ScreenCommanderError.inputSynthesisFailed("pid tap rejected")

        let result = try await fixture.engine.click(elementClickRequest())

        let click = try XCTUnwrap(fixture.mouse.calls.first)
        XCTAssertEqual(click.destination, .global)
        XCTAssertEqual(result.deliveryMethod, .global)
    }

    func testElementClickNoCursorNeverReachesGlobal() async {
        let fixture = makeElementClickFixture("wp5-no-cursor", records: [buttonRecord(actions: [])])
        fixture.mouse.pidClickError = ScreenCommanderError.inputSynthesisFailed("pid tap rejected")

        await assertThrows(
            try await fixture.engine.click(elementClickRequest(noCursor: true))
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "input_synthesis_failed")
        }
        XCTAssertTrue(fixture.mouse.calls.isEmpty, "--no-cursor must never post a global click")
    }

    func testElementClickForcedViaPidSkipsAX() async throws {
        let fixture = makeElementClickFixture("wp5-via-pid", records: [buttonRecord()])

        let result = try await fixture.engine.click(elementClickRequest(via: .pid))

        XCTAssertTrue(fixture.axActions.performedActions.isEmpty, "--via pid must not try the AX tier")
        XCTAssertEqual(fixture.mouse.calls.first?.destination, .pid(77))
        XCTAssertEqual(result.requestedVia, .pid)
        XCTAssertEqual(result.deliveryMethod, .pid)
    }

    func testElementClickForcedViaAXUnsupportedThrows72() async {
        let fixture = makeElementClickFixture("wp5-via-ax-unsupported", records: [buttonRecord(actions: [])])

        await assertThrows(
            try await fixture.engine.click(elementClickRequest(via: .ax))
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "element_not_actionable")
            XCTAssertEqual((error as? ScreenCommanderError)?.exitCode, 72)
        }
        XCTAssertTrue(fixture.mouse.calls.isEmpty, "--via ax must not fall back to mouse delivery")
    }

    func testElementClickDisabledElementStrictThrows72() async {
        let fixture = makeElementClickFixture("wp5-strict-disabled", records: [buttonRecord(enabled: false)])

        await assertThrows(
            try await fixture.engine.click(elementClickRequest(strict: true))
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "element_not_actionable")
            XCTAssertEqual((error as? ScreenCommanderError)?.exitCode, 72)
        }
        XCTAssertTrue(fixture.mouse.calls.isEmpty, "--strict must not downgrade to pid/global")
        XCTAssertTrue(fixture.axActions.performedActions.isEmpty)
    }

    func testElementClickNotFoundThrows70() async {
        let fixture = makeElementClickFixture("wp5-not-found", records: [buttonRecord(title: "Cancel")])

        await assertThrows(
            try await fixture.engine.click(elementClickRequest(element: "Save"))
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "element_not_found")
            XCTAssertEqual((error as? ScreenCommanderError)?.exitCode, 70)
        }
        XCTAssertTrue(fixture.mouse.calls.isEmpty)
    }

    func testElementClickResolvesFreshOnEveryInvocation() async throws {
        let fixture = makeInputEngineFixture("wp5-fresh-resolution", frontmostApp: Self.targetApp)
        fixture.reader.treeResults = [
            AXTreeResult(axPrimed: false, truncated: false, elements: [buttonRecord(id: "0.1")]),
            AXTreeResult(axPrimed: false, truncated: false, elements: [buttonRecord(id: "0.4")])
        ]

        let first = try await fixture.engine.click(elementClickRequest())
        let second = try await fixture.engine.click(elementClickRequest())

        XCTAssertEqual(fixture.reader.treeCalls.count, 2, "each click must re-read the tree")
        XCTAssertEqual(fixture.reader.resolveCalls.map(\.id), ["0.1", "0.4"], "ids must be resolved fresh, never cached")
        XCTAssertEqual(first.element?.id, "0.1")
        XCTAssertEqual(second.element?.id, "0.4")
    }

    func testElementClickByIdAndRoleFilter() async throws {
        let records = [
            buttonRecord(id: "0.0", role: "AXStaticText", title: "Save", actions: []),
            buttonRecord(id: "0.2", role: "AXButton", title: "Save")
        ]
        let fixture = makeElementClickFixture("wp5-id-role", records: records)

        // Role filter steers a substring match away from the static text.
        let byRole = try await fixture.engine.click(elementClickRequest(role: "button"))
        XCTAssertEqual(byRole.element?.id, "0.2")

        // Direct id addressing.
        let byID = try await fixture.engine.click(elementClickRequest(element: nil, elementID: "0.2"))
        XCTAssertEqual(byID.element?.id, "0.2")
        XCTAssertEqual(byID.deliveryMethod, .ax)
    }

    func testElementClickResolvesAppThroughTargets() async throws {
        let fixture = makeElementClickFixture("wp5-app-resolution", records: [buttonRecord()])
        let otherApp = ResolvedApp(pid: 99, name: "OtherApp", bundleID: nil)
        fixture.targets.apps["OtherApp"] = otherApp

        _ = try await fixture.engine.click(elementClickRequest(app: "OtherApp"))

        XCTAssertEqual(fixture.targets.resolveCalls, ["OtherApp"])
        XCTAssertEqual(fixture.reader.treeCalls.first?.app, otherApp)
    }

    func testElementClickDoubleClickSkipsAXTier() async throws {
        let fixture = makeElementClickFixture("wp5-double-skips-ax", records: [buttonRecord()])

        let result = try await fixture.engine.click(elementClickRequest(double: true))

        XCTAssertTrue(fixture.axActions.performedActions.isEmpty, "AXPress cannot express a double-click")
        let click = try XCTUnwrap(fixture.mouse.calls.first)
        XCTAssertTrue(click.doubleClick)
        XCTAssertEqual(click.destination, .pid(77))
        XCTAssertEqual(result.deliveryMethod, .pid)
    }

    func testElementClickRightButtonUsesAXShowMenu() async throws {
        let fixture = makeElementClickFixture(
            "wp5-show-menu",
            records: [buttonRecord(actions: ["AXPress", "AXShowMenu"])]
        )

        let result = try await fixture.engine.click(elementClickRequest(button: .right))

        XCTAssertEqual(fixture.axActions.performedActions, ["AXShowMenu"])
        XCTAssertEqual(result.deliveryMethod, .ax)
    }

    func testCoordinateClickVerifyTargetIncludesHitElement() async throws {
        let fixture = makeInputEngineFixture("wp5-verify-target")
        let hit = buttonRecord(id: "0.9", title: "OK")
        fixture.reader.elementAtResult = hit

        let result = try await fixture.engine.click(
            ClickRequest(
                x: 200,
                y: 100,
                coordinateSpace: .pixels,
                metadataPath: nil,
                button: .left,
                doubleClick: false,
                triple: false,
                primeClick: false,
                humanLike: true,
                modifiers: [],
                verifyTarget: true
            )
        )

        XCTAssertEqual(fixture.reader.elementAtCalls, [CGPoint(x: 200, y: 250)])
        XCTAssertEqual(result.verifiedTarget, hit)
        XCTAssertEqual(fixture.mouse.calls.count, 1, "verification must not suppress the click")
    }

    func testCoordinateClickViaPidRequiresAppAndPostsToPid() async throws {
        let fixture = makeInputEngineFixture("wp5-coordinate-pid")

        await assertThrows(
            try await fixture.engine.click(
                ClickRequest(
                    x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
                    button: .left, doubleClick: false, triple: false,
                    primeClick: false, humanLike: true, modifiers: [],
                    via: .pid
                )
            )
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "invalid_arguments")
        }

        fixture.targets.apps["TargetApp"] = Self.targetApp
        let result = try await fixture.engine.click(
            ClickRequest(
                x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
                button: .left, doubleClick: false, triple: false,
                primeClick: false, humanLike: true, modifiers: [],
                appIdentifier: "TargetApp", via: .pid
            )
        )

        XCTAssertEqual(fixture.mouse.calls.first?.destination, .pid(77))
        XCTAssertEqual(result.deliveryMethod, .pid)
        XCTAssertEqual(result.requestedVia, .pid)
    }

    func testTypeElementSetsValueViaAX() async throws {
        let fixture = makeInputEngineFixture("wp5-type-ax", frontmostApp: Self.targetApp)
        fixture.reader.treeResult = AXTreeResult(
            axPrimed: false,
            truncated: false,
            elements: [buttonRecord(id: "0.3", role: "AXTextField", title: "Name", actions: [])]
        )

        let result = try await fixture.engine.type(
            TypeRequest(text: "hello", delayMilliseconds: nil, inputMode: .paste, element: "Name")
        )

        XCTAssertEqual(fixture.axActions.setValues, ["hello"])
        XCTAssertTrue(fixture.keyboard.pasted.isEmpty)
        XCTAssertTrue(fixture.keyboard.typed.isEmpty)
        XCTAssertEqual(result.deliveryMethod, .ax)
        XCTAssertEqual(result.element?.id, "0.3")
        XCTAssertEqual(result.textLength, 5)
    }

    func testTypeElementFallsBackToFocusPlusKeyboard() async throws {
        let fixture = makeInputEngineFixture("wp5-type-fallback", frontmostApp: Self.targetApp)
        fixture.reader.treeResult = AXTreeResult(
            axPrimed: false,
            truncated: false,
            elements: [buttonRecord(id: "0.3", role: "AXTextField", title: "Name", actions: [])]
        )
        fixture.axActions.setValueError = ScreenCommanderError.elementNotActionable("AXValue is read-only here")

        let result = try await fixture.engine.type(
            TypeRequest(text: "hello", delayMilliseconds: nil, inputMode: .paste, element: "Name")
        )

        XCTAssertEqual(fixture.axActions.focusCount, 1, "fallback should focus the element first")
        XCTAssertEqual(fixture.keyboard.pasted, ["hello"])
        XCTAssertEqual(result.deliveryMethod, .global)
    }

    func testTypeRejectsPidTierAndBareViaAX() async {
        let fixture = makeInputEngineFixture("wp5-type-invalid-via", frontmostApp: Self.targetApp)

        await assertThrows(
            try await fixture.engine.type(
                TypeRequest(text: "x", delayMilliseconds: nil, inputMode: .paste, element: "Name", via: .pid)
            )
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "invalid_arguments")
        }

        await assertThrows(
            try await fixture.engine.type(
                TypeRequest(text: "x", delayMilliseconds: nil, inputMode: .paste, via: .ax)
            )
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "invalid_arguments")
        }
    }

    func testTypeElementForcedViaAXFailureThrows72() async {
        let fixture = makeInputEngineFixture("wp5-type-via-ax-strict", frontmostApp: Self.targetApp)
        fixture.reader.treeResult = AXTreeResult(
            axPrimed: false,
            truncated: false,
            elements: [buttonRecord(id: "0.3", role: "AXTextField", title: "Name", actions: [])]
        )
        fixture.axActions.setValueError = ScreenCommanderError.elementNotActionable("AXValue is read-only here")

        await assertThrows(
            try await fixture.engine.type(
                TypeRequest(text: "x", delayMilliseconds: nil, inputMode: .paste, element: "Name", via: .ax)
            )
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "element_not_actionable")
            XCTAssertEqual((error as? ScreenCommanderError)?.exitCode, 72)
        }
        XCTAssertTrue(fixture.keyboard.pasted.isEmpty, "--via ax must not fall back to the keyboard")
    }

    func testElementScrollUsesPidTierThenGlobal() async throws {
        let fixture = makeInputEngineFixture("wp5-scroll-element", frontmostApp: Self.targetApp)
        fixture.reader.treeResult = AXTreeResult(
            axPrimed: false,
            truncated: false,
            elements: [buttonRecord(id: "0.5", role: "AXScrollArea", title: "Content", actions: [])]
        )

        let result = try await fixture.engine.scroll(
            ScrollRequest(x: nil, y: nil, coordinateSpace: .pixels, metadataPath: nil, dx: 0, dy: -3, unit: .lines, element: "Content")
        )

        let call = try XCTUnwrap(fixture.mouse.scrollCalls.first)
        XCTAssertEqual(call.destination, .pid(77))
        XCTAssertEqual(call.point, CGPoint(x: 120, y: 210))
        XCTAssertEqual(result.deliveryMethod, .pid)
        XCTAssertEqual(result.element?.id, "0.5")

        // pid posting failure downgrades to global (recorded, not an error).
        let fallbackFixture = makeInputEngineFixture("wp5-scroll-element-fallback", frontmostApp: Self.targetApp)
        fallbackFixture.reader.treeResult = fixture.reader.treeResult
        fallbackFixture.mouse.pidScrollError = ScreenCommanderError.inputSynthesisFailed("pid tap rejected")

        let fallback = try await fallbackFixture.engine.scroll(
            ScrollRequest(x: nil, y: nil, coordinateSpace: .pixels, metadataPath: nil, dx: 0, dy: -3, unit: .lines, element: "Content")
        )
        XCTAssertEqual(fallbackFixture.mouse.scrollCalls.first?.destination, .global)
        XCTAssertEqual(fallback.deliveryMethod, .global)
    }

    func testElementScrollRejectsAXTier() async {
        let fixture = makeInputEngineFixture("wp5-scroll-via-ax", frontmostApp: Self.targetApp)

        await assertThrows(
            try await fixture.engine.scroll(
                ScrollRequest(x: nil, y: nil, coordinateSpace: .pixels, metadataPath: nil, dx: 0, dy: -3, unit: .lines, element: "Content", via: .ax)
            )
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "invalid_arguments")
        }
    }

    func testSequenceDecodesElementClickAndTypeSteps() throws {
        let data = Data("""
        {"steps":[
            {"click":{"element":"Save","role":"button","app":"TargetApp","via":"ax","noCursor":true,"strict":true}},
            {"click":{"elementId":"0.3.2"}},
            {"type":{"text":"hi","element":"Name","via":"ax"}}
        ]}
        """.utf8)
        let file = try JSONDecoder().decode(SequenceFile.self, from: data)

        guard case .click(let click) = file.steps[0] else {
            return XCTFail("Expected click step.")
        }
        XCTAssertNil(click.x)
        XCTAssertEqual(click.element, "Save")
        XCTAssertEqual(click.role, "button")
        XCTAssertEqual(click.app, "TargetApp")
        XCTAssertEqual(click.via, .ax)
        XCTAssertEqual(click.noCursor, true)
        XCTAssertEqual(click.strict, true)

        guard case .click(let byID) = file.steps[1] else {
            return XCTFail("Expected click step.")
        }
        XCTAssertEqual(byID.elementId, "0.3.2")

        guard case .type(let type) = file.steps[2] else {
            return XCTFail("Expected type step.")
        }
        XCTAssertEqual(type.element, "Name")
        XCTAssertEqual(type.via, .ax)
    }

    // MARK: - observe

    private final class EventCollector: @unchecked Sendable {
        var events: [ObservedEvent] = []
    }

    private func makeObserveEngine(
        stateName: String,
        permissions: FakePermissions = FakePermissions(),
        targets: FakeTargets,
        reader: FakeAccessibilityReader = FakeAccessibilityReader(),
        source: FakeObservationSource
    ) -> ScreenCommanderEngine {
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath(stateName).path])
        let metadataStore = FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL)
        return ScreenCommanderEngine(
            permissions: permissions,
            displays: NoopDisplays(),
            capturer: FakeCapturer(
                captureResult: CapturedScreenshot(
                    image: make1x1Image(),
                    displayID: 1,
                    displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                    pointPixelScale: 1
                )
            ),
            imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
            metadataStore: metadataStore,
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: FakeRetentionManager(),
            accessibilityReader: reader,
            targets: targets,
            observationSource: source,
            frontmostApp: { nil },
            statePaths: state,
            fileManager: .default
        )
    }

    private func event(_ kind: ObservedEventKind, _ name: String, element: AXElementRecord? = nil) -> ObservedEvent {
        ObservedEvent(
            ts: "2026-07-06T12:00:00.000Z",
            kind: kind,
            event: name,
            app: ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil),
            element: element
        )
    }

    func testObserveResolvesAppChecksPermissionAndForwardsKinds() async throws {
        let permissions = FakePermissions()
        let targets = FakeTargets()
        let app = ResolvedApp(pid: 42, name: "TextEdit", bundleID: "com.apple.TextEdit")
        targets.apps["TextEdit"] = app
        let source = FakeObservationSource()
        source.scriptedEvents = []

        let engine = makeObserveEngine(stateName: "observe-resolve", permissions: permissions, targets: targets, source: source)
        let collector = EventCollector()

        let outcome = try await engine.observe(
            ObserveRequest(appIdentifier: "TextEdit", kinds: [.value, .focus])
        ) { event in
            collector.events.append(event)
        }

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(permissions.accessibilityChecks, 1)
        XCTAssertEqual(targets.resolveCalls, ["TextEdit"])
        XCTAssertEqual(source.requestedApp, app)
        XCTAssertEqual(source.requestedKinds, [.value, .focus])
    }

    func testObserveFiltersEmittedEventsByKind() async throws {
        let targets = FakeTargets()
        targets.apps["TextEdit"] = ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil)
        let source = FakeObservationSource()
        source.scriptedEvents = [
            event(.value, "value_changed"),
            event(.app, "app_activated"),
            event(.focus, "focus_changed")
        ]

        let engine = makeObserveEngine(stateName: "observe-filter", targets: targets, source: source)
        let collector = EventCollector()

        let outcome = try await engine.observe(
            ObserveRequest(appIdentifier: "TextEdit", kinds: [.value, .focus])
        ) { event in
            collector.events.append(event)
        }

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(collector.events.map(\.event), ["value_changed", "focus_changed"])
    }

    func testObserveUntilMatchesIncomingEvent() async throws {
        let targets = FakeTargets()
        targets.apps["TextEdit"] = ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil)
        let matching = AXElementRecord(id: "0.1", role: "AXButton", title: "Save File")
        let source = FakeObservationSource()
        source.scriptedEvents = [
            event(.value, "value_changed", element: AXElementRecord(id: "0.0", role: "AXTextField", title: "Body")),
            event(.value, "value_changed", element: matching),
            event(.value, "value_changed", element: AXElementRecord(id: "0.2", role: "AXButton", title: "Cancel"))
        ]
        // Initial scan finds nothing.
        let reader = FakeAccessibilityReader()
        reader.treeResult = AXTreeResult(axPrimed: false, truncated: false, elements: [])

        let engine = makeObserveEngine(stateName: "observe-until", targets: targets, reader: reader, source: source)
        let collector = EventCollector()

        let outcome = try await engine.observe(
            ObserveRequest(
                appIdentifier: "TextEdit",
                predicate: try ObservePredicate.parse("role=AXButton title~=Save")
            )
        ) { event in
            collector.events.append(event)
        }

        XCTAssertEqual(outcome, .matched(matching))
        // Emission stops at the matching event; the trailing Cancel event is not emitted.
        XCTAssertEqual(collector.events.count, 2)
        XCTAssertEqual(collector.events.last?.element, matching)
    }

    func testObserveInitialScanMatchesImmediately() async throws {
        let targets = FakeTargets()
        targets.apps["Finder"] = ResolvedApp(pid: 99, name: "Finder", bundleID: nil)
        let existing = AXElementRecord(id: "0.3", role: "AXWindow", title: "Downloads")
        let reader = FakeAccessibilityReader()
        reader.treeResult = AXTreeResult(
            axPrimed: false,
            truncated: false,
            elements: [AXElementRecord(id: "0", role: "AXApplication"), existing]
        )
        let source = FakeObservationSource()
        source.scriptedEvents = [event(.window, "window_created")]

        let engine = makeObserveEngine(stateName: "observe-initial", targets: targets, reader: reader, source: source)
        let collector = EventCollector()

        let outcome = try await engine.observe(
            ObserveRequest(
                appIdentifier: "Finder",
                predicate: try ObservePredicate.parse("role=AXWindow title~=Downloads")
            )
        ) { event in
            collector.events.append(event)
        }

        XCTAssertEqual(outcome, .matched(existing))
        // Already-true condition returns before the live source is ever consulted.
        XCTAssertTrue(collector.events.isEmpty)
        XCTAssertNil(source.requestedApp)
    }

    func testObserveTimeoutWithUntilReturns73Outcome() async throws {
        let targets = FakeTargets()
        targets.apps["TextEdit"] = ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil)
        let source = FakeObservationSource()
        source.keepOpen = true // never yields, never finishes → timeout wins

        let engine = makeObserveEngine(stateName: "observe-timeout-until", targets: targets, source: source)

        let outcome = try await engine.observe(
            ObserveRequest(
                appIdentifier: "TextEdit",
                timeoutMS: 50,
                predicate: try ObservePredicate.parse("role=AXButton")
            )
        ) { _ in }

        XCTAssertEqual(outcome, .timedOutUnmet)
    }

    func testObservePlainTimeoutReturnsTimedOut() async throws {
        let targets = FakeTargets()
        targets.apps["TextEdit"] = ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil)
        let source = FakeObservationSource()
        source.keepOpen = true

        let engine = makeObserveEngine(stateName: "observe-timeout-plain", targets: targets, source: source)

        let outcome = try await engine.observe(
            ObserveRequest(appIdentifier: "TextEdit", timeoutMS: 50)
        ) { _ in }

        XCTAssertEqual(outcome, .timedOut)
    }

    func testObserveRejectsNegativeTimeout() async {
        let targets = FakeTargets()
        targets.apps["TextEdit"] = ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil)
        let engine = makeObserveEngine(stateName: "observe-neg-timeout", targets: targets, source: FakeObservationSource())

        do {
            _ = try await engine.observe(ObserveRequest(appIdentifier: "TextEdit", timeoutMS: -1)) { _ in }
            XCTFail("Expected invalid_arguments")
        } catch let error as ScreenCommanderError {
            XCTAssertEqual(error.stableCode, "invalid_arguments")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testObserveDeniedAccessibilityStopsBeforeResolvingApp() async {
        let permissions = FakePermissions()
        permissions.allowAccessibility = false
        let targets = FakeTargets()
        targets.apps["TextEdit"] = ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil)
        let source = FakeObservationSource()

        let engine = makeObserveEngine(stateName: "observe-denied", permissions: permissions, targets: targets, source: source)

        do {
            _ = try await engine.observe(ObserveRequest(appIdentifier: "TextEdit")) { _ in }
            XCTFail("Expected permission error")
        } catch let error as ScreenCommanderError {
            XCTAssertEqual(error.stableCode, "permission_denied_accessibility")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertTrue(targets.resolveCalls.isEmpty)
        XCTAssertNil(source.requestedApp)
    }

    func testObserveSurfacesObserverSetupFailure() async {
        let targets = FakeTargets()
        targets.apps["TextEdit"] = ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil)
        let source = FakeObservationSource()
        // No `--until`, so the source (not the initial scan) is consulted; it fails
        // setup instead of finishing cleanly.
        source.setupError = ScreenCommanderError.axTreeUnavailable("no observer")

        let engine = makeObserveEngine(stateName: "observe-setup-fail", targets: targets, source: source)

        do {
            _ = try await engine.observe(ObserveRequest(appIdentifier: "TextEdit", kinds: [.value])) { _ in }
            XCTFail("Expected ax_tree_unavailable")
        } catch let error as ScreenCommanderError {
            XCTAssertEqual(error.stableCode, "ax_tree_unavailable")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
