import CoreGraphics
import Foundation
import XCTest
@testable import ScreenCommander

// Compact fakes for the MCP fixture. The engine-test fakes are file-private to
// ScreenCommanderEngineTests.swift, so the ones the MCP transcript needs are
// duplicated here in minimal form.

private final class MCPFakePermissions: PermissionChecking {
    func ensureScreenRecordingAccess(prompt: Bool) throws {}
    func ensureAccessibilityAccess(prompt: Bool) throws {}
}

private final class MCPNoopDisplays: DisplayResolving {
    func resolveDisplay(identifier: String) async throws -> ResolvedDisplay {
        throw ScreenCommanderError.invalidArguments("Display capture is not used in MCP tests.")
    }
}

private final class MCPFakeCapturer: ScreenCapturing {
    let captured: CapturedScreenshot

    init(captured: CapturedScreenshot) {
        self.captured = captured
    }

    func capture(display: ResolvedDisplay, includeCursor: Bool) async throws -> CapturedScreenshot {
        captured
    }

    func capture(window: ResolvedWindow, includeCursor: Bool) async throws -> CapturedScreenshot {
        captured
    }
}

private final class MCPFakeImageWriter: ImageWriting {
    func write(image: CGImage, format: ImageFormat, to url: URL) throws -> SizeD {
        SizeD(w: Double(image.width), h: Double(image.height))
    }
}

private final class MCPFakeMetadataStore: SnapshotMetadataStoring {
    let defaultLastMetadataURL: URL
    private var stored: [String: ScreenshotMetadata] = [:]

    init(defaultLastMetadataURL: URL) {
        self.defaultLastMetadataURL = defaultLastMetadataURL
    }

    func save(metadata: ScreenshotMetadata, at metadataURL: URL, updateLastAt lastURL: URL?) throws {
        stored[metadataURL.path] = metadata
        if let lastURL {
            stored[lastURL.path] = metadata
        }
    }

    func load(from metadataURL: URL) throws -> ScreenshotMetadata {
        guard let metadata = stored[metadataURL.path] else {
            throw ScreenCommanderError.metadataFailure("Missing metadata at \(metadataURL.path)")
        }
        return metadata
    }

    func seedLoad(_ metadata: ScreenshotMetadata, at url: URL) {
        stored[url.path] = metadata
    }
}

private final class MCPFakeMouse: MouseControlling {
    private(set) var clickPoints: [CGPoint] = []

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
        clickPoints.append(point)
    }

    func scroll(at point: CGPoint, dx: Int32, dy: Int32, unit: ScrollUnit, destination: MouseEventDestination) throws {}
    func drag(from start: CGPoint, to end: CGPoint, button: MouseButtonChoice, steps: Int, durationMS: Int) throws {}
    func move(to point: CGPoint) throws {}
}

private final class MCPFakeKeyboard: KeyboardControlling {
    private(set) var runCount = 0

    func type(text: String, delayMilliseconds: Int?) throws {}
    func typeByPasting(text: String) throws {}
    func press(chord: ParsedKeyChord) throws {}
    func pressSystemKey(_ key: SystemKey) throws {}
    func run(sequence: KeySequence) throws { runCount += 1 }
}

private final class MCPFakeRetention: CaptureRetentionManaging {
    func pruneCaptures(in directory: URL, olderThan: TimeInterval, now: Date) throws -> CleanupResult {
        CleanupResult(deletedCount: 0, deletedBytesApprox: 0)
    }
}

private final class MCPFakeTargets: TargetResolving {
    var apps: [String: ResolvedApp] = [:]
    var windows: [String: WindowInfo] = [:]

    func resolveApp(identifier: String) async throws -> ResolvedApp {
        guard let app = apps[identifier] else {
            throw ScreenCommanderError.appNotFound("No app for '\(identifier)' in fake.")
        }
        return app
    }

    func listWindows(app: ResolvedApp?) async throws -> [WindowInfo] {
        Array(windows.values)
    }

    func resolveWindow(identifier: String, app: ResolvedApp?) async throws -> ResolvedWindow {
        guard let info = windows[identifier] else {
            throw ScreenCommanderError.windowNotFound("No window for '\(identifier)' in fake.")
        }
        return ResolvedWindow(info: info, scWindow: nil)
    }
}

private final class MCPFakeReader: AccessibilityReading {
    var treeResult = AXTreeResult(axPrimed: false, truncated: false, elements: [])

    func tree(app: ResolvedApp, options: AXTreeOptions) throws -> AXTreeResult {
        treeResult
    }

    func elementAt(globalPoint: CGPoint) throws -> AXElementRecord? {
        nil
    }

    func resolve(id: String, app: ResolvedApp) throws -> AXElement {
        AXElement.application(pid: app.pid)
    }
}

private final class MCPFakeAXActions: AXActionPerforming {
    func perform(action: String, on element: AXElement) throws {}
    func setValue(_ value: String, on element: AXElement) throws {}
    func focus(on element: AXElement) throws {}
}

private final class MCPFakeObservation: ObservationSource, @unchecked Sendable {
    var scriptedEvents: [ObservedEvent] = []
    var keepOpen = false

    func events(app: ResolvedApp, kinds: Set<ObservedEventKind>) -> AsyncThrowingStream<ObservedEvent, Error> {
        let events = scriptedEvents
        let keepOpen = keepOpen
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            if !keepOpen {
                continuation.finish()
            }
        }
    }
}

private struct MCPFakeDoctor: DoctorReporting {
    func collect() throws -> DoctorReport {
        DoctorReport(
            permissions: DoctorPermissionStatus(screenRecordingGranted: true, accessibilityGranted: false),
            displays: [DoctorDisplayStatus(displayID: 1, isMain: true, boundsPoints: RectD(x: 0, y: 0, w: 1728, h: 1117))]
        )
    }
}

private func makeTestImage() -> CGImage {
    let data = Data([255, 0, 0, 255])
    let provider = CGDataProvider(data: data as CFData)!
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
    return CGImage(
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private struct MCPFixture {
    let server: MCPServer
    let registry: MCPToolRegistry
    let mouse: MCPFakeMouse
    let keyboard: MCPFakeKeyboard
    let targets: MCPFakeTargets
    let observation: MCPFakeObservation
}

private func makeFixture(_ name: String, now: @escaping () -> Date = Date.init) -> MCPFixture {
    let stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("screencommander-mcp-tests", isDirectory: true)
        .appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

    let statePaths = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": stateDir.path])
    let metadataStore = MCPFakeMetadataStore(defaultLastMetadataURL: statePaths.lastMetadataURL)
    metadataStore.seedLoad(
        ScreenshotMetadata(
            capturedAtISO8601: "2026-07-06T00:00:00Z",
            displayID: 1,
            displayBoundsPoints: RectD(x: 0, y: 0, w: 400, h: 300),
            imageSizePixels: SizeD(w: 800, h: 600),
            pointPixelScale: 2,
            imagePath: "/tmp/test.png"
        ),
        at: statePaths.lastMetadataURL
    )

    let mouse = MCPFakeMouse()
    let keyboard = MCPFakeKeyboard()
    let targets = MCPFakeTargets()
    let observation = MCPFakeObservation()

    let engine = ScreenCommanderEngine(
        permissions: MCPFakePermissions(),
        displays: MCPNoopDisplays(),
        capturer: MCPFakeCapturer(
            captured: CapturedScreenshot(
                image: makeTestImage(),
                displayID: 1,
                displayBoundsPoints: CGRect(x: 0, y: 0, width: 400, height: 300),
                pointPixelScale: 2
            )
        ),
        imageWriter: MCPFakeImageWriter(),
        metadataStore: metadataStore,
        coordinateMapper: CoordinateMapper(),
        mouseController: mouse,
        keyboardController: keyboard,
        retention: MCPFakeRetention(),
        accessibilityReader: MCPFakeReader(),
        axActions: MCPFakeAXActions(),
        targets: targets,
        observationSource: observation,
        frontmostApp: { nil },
        activateApp: { _ in },
        statePaths: statePaths,
        now: now
    )

    let registry = MCPToolRegistry(engine: engine, doctor: MCPFakeDoctor())
    return MCPFixture(
        server: MCPServer(registry: registry),
        registry: registry,
        mouse: mouse,
        keyboard: keyboard,
        targets: targets,
        observation: observation
    )
}

private func decodeResponse(_ line: String?) throws -> JSONValue {
    let unwrapped = try XCTUnwrap(line)
    return try JSONDecoder().decode(JSONValue.self, from: Data(unwrapped.utf8))
}

private func initializeMCP(_ server: MCPServer) async throws {
    let response = try decodeResponse(await server.handle(
        line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#
    ))
    XCTAssertNil(response["error"])
}

private final class MCPOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func waitForResponse(id: Int, timeoutMS: Int = 1_000) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1_000)
        while Date() < deadline {
            for line in snapshot() {
                let value = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
                if value["id"]?.intValue == id {
                    return value
                }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ScreenCommanderError.observeTimeout("No MCP response for id \(id).")
    }

    func hasResponse(id: Int) throws -> Bool {
        for line in snapshot() {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            if value["id"]?.intValue == id {
                return true
            }
        }
        return false
    }
}

final class MCPServerTests: XCTestCase {
    private let expectedToolNames: Set<String> = [
        "screenshot", "click", "type", "key", "keys", "scroll", "drag", "move",
        "elements", "windows", "focus", "observe_wait", "doctor", "cleanup",
    ]

    func testInitializeHandshake() async throws {
        let fixture = makeFixture("initialize")
        let response = try decodeResponse(await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{}}}"#
        ))

        XCTAssertEqual(response["id"]?.intValue, 1)
        let result = try XCTUnwrap(response["result"])
        // We speak exactly one revision; an unsupported request gets OUR version
        // back (per the MCP lifecycle spec), never an echo of an unknown one.
        XCTAssertEqual(result["protocolVersion"]?.stringValue, MCPServer.protocolVersion)
        XCTAssertEqual(result["serverInfo"]?["name"]?.stringValue, "screencommander")
        XCTAssertNotNil(result["capabilities"]?["tools"])
    }

    func testNotificationGetsNoResponse() async throws {
        let fixture = makeFixture("notification")
        let response = await fixture.server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(response)
    }

    func testServeSessionRunsUnrelatedRequestsInParallel() async throws {
        let fixture = makeFixture("serve-parallel")
        fixture.targets.apps["TextEdit"] = ResolvedApp(pid: 200, name: "TextEdit", bundleID: nil)
        fixture.observation.keepOpen = true
        let output = MCPOutputCollector()
        let session = MCPServeSession(server: fixture.server) { output.append($0) }

        session.receive(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#)
        _ = try await output.waitForResponse(id: 1)

        session.receive(line: #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"observe_wait","arguments":{"app":"TextEdit","timeoutMs":5000}}}"#)
        session.receive(line: #"{"jsonrpc":"2.0","id":11,"method":"ping"}"#)

        let ping = try await output.waitForResponse(id: 11, timeoutMS: 500)
        XCTAssertNotNil(ping["result"])
        XCTAssertFalse(try output.hasResponse(id: 10), "unrelated ping should return before the long observe_wait")

        session.receive(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":10}}"#)
    }

    func testServeSessionSerialDependencyWaitsForUpstream() async throws {
        let fixture = makeFixture("serve-serial")
        fixture.targets.apps["TextEdit"] = ResolvedApp(pid: 200, name: "TextEdit", bundleID: nil)
        fixture.observation.keepOpen = true
        let output = MCPOutputCollector()
        let session = MCPServeSession(server: fixture.server) { output.append($0) }

        session.receive(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#)
        _ = try await output.waitForResponse(id: 1)

        session.receive(line: #"{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"observe_wait","arguments":{"app":"TextEdit","timeoutMs":150}}}"#)
        session.receive(line: #"{"jsonrpc":"2.0","id":21,"method":"ping","params":{"dependsOn":20}}"#)

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(try output.hasResponse(id: 21), "dependent ping must wait for upstream observe_wait")

        let upstream = try await output.waitForResponse(id: 20, timeoutMS: 1_000)
        XCTAssertNotNil(upstream["result"])
        let dependent = try await output.waitForResponse(id: 21, timeoutMS: 1_000)
        XCTAssertNotNil(dependent["result"])
    }

    func testServeSessionCancellationSuppressesLateResponseAndDependents() async throws {
        let fixture = makeFixture("serve-cancel")
        fixture.targets.apps["TextEdit"] = ResolvedApp(pid: 200, name: "TextEdit", bundleID: nil)
        fixture.observation.keepOpen = true
        let output = MCPOutputCollector()
        let session = MCPServeSession(server: fixture.server) { output.append($0) }

        session.receive(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#)
        _ = try await output.waitForResponse(id: 1)

        session.receive(line: #"{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"observe_wait","arguments":{"app":"TextEdit","timeoutMs":5000}}}"#)
        session.receive(line: #"{"jsonrpc":"2.0","id":31,"method":"ping","params":{"dependsOn":30}}"#)
        session.receive(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":30}}"#)

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(try output.hasResponse(id: 30))
        XCTAssertFalse(try output.hasResponse(id: 31))
    }

    func testServeSessionLateCancelDoesNotCancelCompletedDependencyFollower() async throws {
        let fixture = makeFixture("serve-late-cancel")
        fixture.targets.apps["TextEdit"] = ResolvedApp(pid: 200, name: "TextEdit", bundleID: nil)
        fixture.observation.keepOpen = true
        let output = MCPOutputCollector()
        let session = MCPServeSession(server: fixture.server) { output.append($0) }

        session.receive(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#)
        _ = try await output.waitForResponse(id: 1)

        session.receive(line: #"{"jsonrpc":"2.0","id":40,"method":"ping"}"#)
        _ = try await output.waitForResponse(id: 40)

        session.receive(line: #"{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"dependsOn":40,"name":"observe_wait","arguments":{"app":"TextEdit","timeoutMs":50,"until":"title~=never"}}}"#)
        session.receive(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":40}}"#)

        let dependent = try await output.waitForResponse(id: 41, timeoutMS: 1_000)
        XCTAssertEqual(dependent["result"]?["isError"]?.boolValue, true)
        XCTAssertEqual(dependent["result"]?["structuredContent"]?["error"]?["code"]?.stringValue, "observe_timeout")
    }

    func testServeSessionInheritsScreenshotMetadataForDependentCoordinateAction() async throws {
        let fixture = makeFixture("serve-inherit-metadata")
        let window = WindowInfo(
            windowID: 42,
            title: "Apple",
            appName: "Safari",
            pid: 100,
            boundsPoints: RectD(x: 0, y: 0, w: 400, h: 300),
            isOnScreen: true,
            layer: 0
        )
        fixture.targets.windows["Safari"] = window
        fixture.targets.windows["42"] = window
        let output = MCPOutputCollector()
        let session = MCPServeSession(server: fixture.server) { output.append($0) }

        session.receive(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#)
        _ = try await output.waitForResponse(id: 1)

        session.receive(line: #"{"jsonrpc":"2.0","id":50,"method":"tools/call","params":{"name":"screenshot","arguments":{"window":"Safari","path":"/tmp/inherited.png","updateLastMetadata":false}}}"#)
        let screenshot = try await output.waitForResponse(id: 50)
        let metadataPath = try XCTUnwrap(screenshot["result"]?["structuredContent"]?["result"]?["metadataPath"]?.stringValue)
        XCTAssertEqual(metadataPath, "/tmp/inherited.json")

        session.receive(line: #"{"jsonrpc":"2.0","id":51,"method":"tools/call","params":{"dependsOn":50,"name":"click","arguments":{"x":0,"y":0}}}"#)
        let click = try await output.waitForResponse(id: 51)
        let action = try XCTUnwrap(click["result"]?["structuredContent"]?["result"]?["action"])
        XCTAssertEqual(action["metadataPath"]?.stringValue, metadataPath)
        XCTAssertEqual(fixture.mouse.clickPoints.count, 1)
    }

    func testParallelSafeDefaultScreenshotPathsAreUniqueWithinSameSecond() async throws {
        let fixture = makeFixture(
            "screenshot-unique-defaults",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        try await initializeMCP(fixture.server)
        fixture.targets.windows["Safari"] = WindowInfo(
            windowID: 42,
            title: "Apple",
            appName: "Safari",
            pid: 100,
            boundsPoints: RectD(x: 0, y: 0, w: 400, h: 300),
            isOnScreen: true,
            layer: 0
        )

        let first = try decodeResponse(await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","id":52,"method":"tools/call","params":{"name":"screenshot","arguments":{"window":"Safari","updateLastMetadata":false}}}"#
        ))
        let second = try decodeResponse(await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","id":53,"method":"tools/call","params":{"name":"screenshot","arguments":{"window":"Safari","updateLastMetadata":false}}}"#
        ))

        let firstPath = try XCTUnwrap(first["result"]?["structuredContent"]?["result"]?["imagePath"]?.stringValue)
        let secondPath = try XCTUnwrap(second["result"]?["structuredContent"]?["result"]?["imagePath"]?.stringValue)
        XCTAssertNotEqual(firstPath, secondPath)
        XCTAssertTrue(URL(fileURLWithPath: firstPath).lastPathComponent.hasPrefix("Screenshot-"))
        XCTAssertTrue(URL(fileURLWithPath: secondPath).lastPathComponent.hasPrefix("Screenshot-"))
    }

    func testBlankLineIsIgnored() async throws {
        let fixture = makeFixture("blank")
        let response = await fixture.server.handle(line: "   ")
        XCTAssertNil(response)
    }

    func testUnknownMethodReturnsMethodNotFound() async throws {
        let fixture = makeFixture("unknown-method")
        let response = try decodeResponse(await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#
        ))
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32601)
    }

    func testUnparseableLineReturnsParseError() async throws {
        let fixture = makeFixture("parse-error")
        let response = try decodeResponse(await fixture.server.handle(line: "not json at all"))
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32700)
        XCTAssertEqual(response["id"], .null)
    }

    func testPing() async throws {
        let fixture = makeFixture("ping")
        let response = try decodeResponse(await fixture.server.handle(line: #"{"jsonrpc":"2.0","id":9,"method":"ping"}"#))
        XCTAssertNotNil(response["result"])
        XCTAssertNil(response["error"])
    }

    func testToolsRequireInitialize() async throws {
        let fixture = makeFixture("preinitialize-tools")

        let listResponse = try decodeResponse(await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","id":30,"method":"tools/list"}"#
        ))
        XCTAssertEqual(listResponse["error"]?["code"]?.intValue, -32600)

        let callResponse = try decodeResponse(await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"doctor"}}"#
        ))
        XCTAssertEqual(callResponse["error"]?["code"]?.intValue, -32600)
    }

    func testInitializedNotificationDoesNotUnlockTools() async throws {
        let fixture = makeFixture("initialized-notification-only")

        let notificationResponse = await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        )
        XCTAssertNil(notificationResponse)

        let response = try decodeResponse(await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","id":32,"method":"tools/list"}"#
        ))
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32600)
    }

    func testToolsListExposesAllFourteenTools() async throws {
        let fixture = makeFixture("tools-list")
        try await initializeMCP(fixture.server)
        let response = try decodeResponse(await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#
        ))

        let tools = try XCTUnwrap(response["result"]?["tools"]?.arrayValue)
        XCTAssertEqual(tools.count, expectedToolNames.count)
        XCTAssertEqual(Set(tools.compactMap { $0["name"]?.stringValue }), expectedToolNames)
        for tool in tools {
            XCTAssertEqual(tool["inputSchema"]?["type"]?.stringValue, "object", "tool \(tool["name"]?.stringValue ?? "?") lacks an object schema")
            XCTAssertNotNil(tool["description"]?.stringValue)
        }
    }

    func testToolsCallDoctorReturnsOkEnvelope() async throws {
        let fixture = makeFixture("doctor")
        try await initializeMCP(fixture.server)
        let response = try decodeResponse(await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"doctor"}}"#
        ))

        let result = try XCTUnwrap(response["result"])
        XCTAssertEqual(result["isError"]?.boolValue, false)

        let envelope = try XCTUnwrap(result["structuredContent"])
        XCTAssertEqual(envelope["status"]?.stringValue, "ok")
        XCTAssertEqual(envelope["command"]?.stringValue, "doctor")
        XCTAssertEqual(envelope["exitCode"]?.intValue, 0)
        XCTAssertEqual(envelope["result"]?["permissions"]?["screenRecordingGranted"]?.boolValue, true)

        // The text block carries the same envelope, so CLI-oriented parsers work unchanged.
        let content = try XCTUnwrap(result["content"]?.arrayValue)
        let textBlock = try XCTUnwrap(content.last)
        XCTAssertEqual(textBlock["type"]?.stringValue, "text")
        let reparsed = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(try XCTUnwrap(textBlock["text"]?.stringValue).utf8)
        )
        XCTAssertEqual(reparsed, envelope)
    }

    func testToolsCallUnknownToolIsInvalidParams() async throws {
        let fixture = makeFixture("unknown-tool")
        try await initializeMCP(fixture.server)
        let response = try decodeResponse(await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"self_destruct"}}"#
        ))
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32602)
    }

    func testToolsCallClickDispatchesToEngine() async throws {
        let fixture = makeFixture("click")
        try await initializeMCP(fixture.server)
        let response = try decodeResponse(await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"click","arguments":{"x":10,"y":10}}}"#
        ))

        XCTAssertEqual(fixture.mouse.clickPoints.count, 1)
        // Pixel (10,10) at scale 2 over a display at points-origin (0,0) → global (5,5).
        XCTAssertEqual(fixture.mouse.clickPoints.first?.x, 5)
        XCTAssertEqual(fixture.mouse.clickPoints.first?.y, 5)

        let envelope = try XCTUnwrap(response["result"]?["structuredContent"])
        XCTAssertEqual(envelope["status"]?.stringValue, "ok")
        XCTAssertEqual(envelope["result"]?["action"]?["deliveryMethod"]?.stringValue, "global")
    }

    func testToolsCallClickWithoutTargetIsToolError() async throws {
        let fixture = makeFixture("click-invalid")
        try await initializeMCP(fixture.server)
        let response = try decodeResponse(await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"click","arguments":{}}}"#
        ))

        let result = try XCTUnwrap(response["result"])
        XCTAssertEqual(result["isError"]?.boolValue, true)
        let envelope = try XCTUnwrap(result["structuredContent"])
        XCTAssertEqual(envelope["status"]?.stringValue, "error")
        XCTAssertEqual(envelope["error"]?["code"]?.stringValue, "invalid_arguments")
        XCTAssertEqual(envelope["exitCode"]?.intValue, 60)
        XCTAssertTrue(fixture.mouse.clickPoints.isEmpty)
    }

    func testToolsCallScreenshotWindowReturnsImageBlock() async throws {
        let fixture = makeFixture("screenshot")
        try await initializeMCP(fixture.server)
        fixture.targets.windows["Safari"] = WindowInfo(
            windowID: 42,
            title: "Apple",
            appName: "Safari",
            pid: 100,
            boundsPoints: RectD(x: 10, y: 20, w: 400, h: 300),
            isOnScreen: true,
            layer: 0
        )

        let response = try decodeResponse(await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"screenshot","arguments":{"window":"Safari","path":"/tmp/mcp-test.png"}}}"#
        ))

        let result = try XCTUnwrap(response["result"])
        XCTAssertEqual(result["isError"]?.boolValue, false)

        let content = try XCTUnwrap(result["content"]?.arrayValue)
        XCTAssertEqual(content.count, 2)
        let imageBlock = content[0]
        XCTAssertEqual(imageBlock["type"]?.stringValue, "image")
        XCTAssertEqual(imageBlock["mimeType"]?.stringValue, "image/png")
        let base64 = try XCTUnwrap(imageBlock["data"]?.stringValue)
        XCTAssertNotNil(Data(base64Encoded: base64))
        XCTAssertFalse(base64.isEmpty)

        let envelope = try XCTUnwrap(result["structuredContent"])
        XCTAssertEqual(envelope["result"]?["metadata"]?["windowID"]?.intValue, 42)
    }

    func testObserveWaitMatchesScriptedEvent() async throws {
        let fixture = makeFixture("observe-match")
        try await initializeMCP(fixture.server)
        let app = ResolvedApp(pid: 200, name: "TextEdit", bundleID: nil)
        fixture.targets.apps["TextEdit"] = app
        fixture.observation.scriptedEvents = [
            ObservedEvent(
                ts: "2026-07-06T00:00:01Z",
                kind: .window,
                event: "window_created",
                app: app,
                element: AXElementRecord(id: "0.1", role: "AXWindow", title: "Save Me")
            )
        ]
        fixture.observation.keepOpen = true

        let response = try decodeResponse(await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"observe_wait","arguments":{"app":"TextEdit","timeoutMs":5000,"until":"title~=save"}}}"#
        ))

        let envelope = try XCTUnwrap(response["result"]?["structuredContent"])
        XCTAssertEqual(envelope["status"]?.stringValue, "ok")
        XCTAssertEqual(envelope["result"]?["outcome"]?.stringValue, "matched")
        XCTAssertEqual(envelope["result"]?["matched"]?["title"]?.stringValue, "Save Me")
        XCTAssertEqual(envelope["result"]?["events"]?.arrayValue?.count, 1)
    }

    func testObserveWaitUnmetPredicateIsObserveTimeoutError() async throws {
        let fixture = makeFixture("observe-timeout")
        try await initializeMCP(fixture.server)
        fixture.targets.apps["TextEdit"] = ResolvedApp(pid: 200, name: "TextEdit", bundleID: nil)
        fixture.observation.keepOpen = true

        let response = try decodeResponse(await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"observe_wait","arguments":{"app":"TextEdit","timeoutMs":50,"until":"title~=never-appears"}}}"#
        ))

        let result = try XCTUnwrap(response["result"])
        XCTAssertEqual(result["isError"]?.boolValue, true)
        let envelope = try XCTUnwrap(result["structuredContent"])
        XCTAssertEqual(envelope["error"]?["code"]?.stringValue, "observe_timeout")
        XCTAssertEqual(envelope["exitCode"]?.intValue, 73)
    }

    // MARK: - Malformed-input regressions (review findings)

    func testScrollRejectsOutOfInt32RangeDeltaInsteadOfTrapping() async throws {
        let fixture = makeFixture("scroll-overflow")
        try await initializeMCP(fixture.server)
        // Int32.max + 1 — previously a trapping Int32() conversion that killed the server.
        let response = try decodeResponse(await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"scroll","arguments":{"x":1,"y":1,"dx":2147483648}}}"#
        ))
        let result = try XCTUnwrap(response["result"])
        XCTAssertEqual(result["isError"]?.boolValue, true)
        XCTAssertEqual(result["structuredContent"]?["error"]?["code"]?.stringValue, "invalid_arguments")
    }

    func testElementsRejectsNegativeWindowIdInsteadOfTrapping() async throws {
        let fixture = makeFixture("elements-negative-window")
        try await initializeMCP(fixture.server)
        // Previously a trapping UInt32() conversion.
        let response = try decodeResponse(await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"elements","arguments":{"windowId":-1}}}"#
        ))
        let result = try XCTUnwrap(response["result"])
        XCTAssertEqual(result["isError"]?.boolValue, true)
        XCTAssertEqual(result["structuredContent"]?["error"]?["code"]?.stringValue, "invalid_arguments")
    }

    func testKeysRejectsMixedTypeStepsWithoutPartialExecution() async throws {
        let fixture = makeFixture("keys-mixed-array")
        try await initializeMCP(fixture.server)
        // Previously compactMap dropped the 5 and executed only press:a.
        let response = try decodeResponse(await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"keys","arguments":{"steps":["press:a",5]}}}"#
        ))
        let result = try XCTUnwrap(response["result"])
        XCTAssertEqual(result["isError"]?.boolValue, true)
        XCTAssertEqual(result["structuredContent"]?["error"]?["code"]?.stringValue, "invalid_arguments")
        XCTAssertEqual(fixture.keyboard.runCount, 0, "malformed step lists must not execute partially")
    }

    func testMalformedBooleanArgumentIsRejectedWithoutPartialExecution() async throws {
        let fixture = makeFixture("malformed-bool")
        try await initializeMCP(fixture.server)

        let response = try decodeResponse(await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","id":24,"method":"tools/call","params":{"name":"click","arguments":{"x":10,"y":10,"strictMetadata":"true"}}}"#
        ))

        let result = try XCTUnwrap(response["result"])
        XCTAssertEqual(result["isError"]?.boolValue, true)
        XCTAssertEqual(result["structuredContent"]?["error"]?["code"]?.stringValue, "invalid_arguments")
        XCTAssertTrue(fixture.mouse.clickPoints.isEmpty, "malformed booleans must not silently default and execute")
    }

    func testToolsCallScreenshotJPEGReturnsJpegImageBlock() async throws {
        let fixture = makeFixture("screenshot-jpeg")
        try await initializeMCP(fixture.server)
        fixture.targets.windows["Safari"] = WindowInfo(
            windowID: 43,
            title: "Apple",
            appName: "Safari",
            pid: 100,
            boundsPoints: RectD(x: 10, y: 20, w: 400, h: 300),
            isOnScreen: true,
            layer: 0
        )

        let response = try decodeResponse(await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"screenshot","arguments":{"window":"Safari","format":"jpeg","path":"/tmp/mcp-test.jpeg"}}}"#
        ))

        let content = try XCTUnwrap(response["result"]?["content"]?.arrayValue)
        XCTAssertEqual(content.count, 2, "jpeg captures must include the in-band image block too")
        XCTAssertEqual(content[0]["type"]?.stringValue, "image")
        XCTAssertEqual(content[0]["mimeType"]?.stringValue, "image/jpeg")
        XCTAssertNotNil(Data(base64Encoded: try XCTUnwrap(content[0]["data"]?.stringValue)))
    }

    func testObserveWaitRejectsOutOfRangeTimeout() async throws {
        let fixture = makeFixture("observe-bad-timeout")
        try await initializeMCP(fixture.server)
        let response = try decodeResponse(await fixture.server.handle(
            line: #"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"observe_wait","arguments":{"app":"TextEdit","timeoutMs":0}}}"#
        ))
        let envelope = try XCTUnwrap(response["result"]?["structuredContent"])
        XCTAssertEqual(envelope["error"]?["code"]?.stringValue, "invalid_arguments")
    }
}
