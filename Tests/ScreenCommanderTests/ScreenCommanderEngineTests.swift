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
        let primeClick: Bool
        let humanLike: Bool
    }

    private(set) var calls: [ClickCall] = []

    func click(
        at point: CGPoint,
        button: MouseButtonChoice,
        doubleClick: Bool,
        primeClick: Bool,
        humanLike: Bool
    ) throws {
        calls.append(ClickCall(point: point, button: button, doubleClick: doubleClick, primeClick: primeClick, humanLike: humanLike))
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
                primeClick: false,
                humanLike: true
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
