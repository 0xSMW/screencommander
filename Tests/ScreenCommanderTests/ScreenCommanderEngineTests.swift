import Foundation
import CoreGraphics
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
    }
    struct ScrollCall {
        let point: CGPoint
        let dx: Int32
        let dy: Int32
        let unit: ScrollUnit
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

    func click(
        at point: CGPoint,
        button: MouseButtonChoice,
        doubleClick: Bool,
        tripleClick: Bool,
        primeClick: Bool,
        humanLike: Bool,
        modifiers: [String]
    ) throws {
        calls.append(
            ClickCall(
                point: point,
                button: button,
                doubleClick: doubleClick,
                tripleClick: tripleClick,
                primeClick: primeClick,
                humanLike: humanLike,
                modifiers: modifiers
            )
        )
    }

    func scroll(at point: CGPoint, dx: Int32, dy: Int32, unit: ScrollUnit) throws {
        scrollCalls.append(ScrollCall(point: point, dx: dx, dy: dy, unit: unit))
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
    let state: StatePaths
}

private func makeInputEngineFixture(_ name: String) -> InputEngineFixture {
    let permissions = FakePermissions()
    let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath(name).path])
    let metadataStore = FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL)
    let mouse = FakeMouseController()
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
        keyboardController: FakeKeyboardController(),
        retention: FakeRetentionManager(),
        statePaths: state,
        fileManager: .default,
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    return InputEngineFixture(engine: engine, permissions: permissions, metadataStore: metadataStore, mouse: mouse, state: state)
}

final class ScreenCommanderEngineTests: XCTestCase {
    func testTypeRejectsNegativeDelay() {
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

        XCTAssertThrowsError(try engine.type(TypeRequest(text: "bad", delayMilliseconds: -5, inputMode: .unicode)))
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

    func testClickLoadsDefaultMetadataPathAndMapsPixels() throws {
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

        let result = try engine.click(
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
        XCTAssertEqual(result.resolved.globalX, 200)
        XCTAssertEqual(result.resolved.globalY, 250)
        XCTAssertEqual(metadataStore.loadCalls, [state.lastMetadataURL])
        XCTAssertEqual(permissions.accessibilityChecks, 1)
    }

    func testScrollCallsMouseController() throws {
        let fixture = makeInputEngineFixture("scroll")

        let result = try fixture.engine.scroll(
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
        XCTAssertEqual(result.resolved.globalX, 200)
        XCTAssertEqual(result.resolved.globalY, 250)
        XCTAssertEqual(result.dx, 4)
        XCTAssertEqual(result.dy, -3)
        XCTAssertEqual(result.unit, .pixels)
        XCTAssertEqual(fixture.permissions.accessibilityChecks, 1)
    }

    func testScrollRequiresNonzeroDelta() {
        let fixture = makeInputEngineFixture("scroll-zero")

        XCTAssertThrowsError(
            try fixture.engine.scroll(
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

    func testClickWithModifiers() throws {
        let fixture = makeInputEngineFixture("click-modifiers")

        let result = try fixture.engine.click(
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

    func testClickTriple() throws {
        let fixture = makeInputEngineFixture("click-triple")

        let result = try fixture.engine.click(
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

    func testClickDoubleAndTripleMutuallyExclusive() {
        let fixture = makeInputEngineFixture("click-double-triple")

        XCTAssertThrowsError(
            try fixture.engine.click(
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

    func testTypeAndKeysFlowThroughKeyboardController() throws {
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

        _ = try engine.type(TypeRequest(text: "hello", delayMilliseconds: 25, inputMode: .unicode))
        _ = try engine.type(TypeRequest(text: "paste", delayMilliseconds: nil, inputMode: .paste))
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
}
