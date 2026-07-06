import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The outcome of one tools/call: the same envelope the CLI prints, plus any extra
/// MCP content blocks (screenshot image data) and the tool-level error marker.
struct MCPToolOutcome {
    /// `CommandEnvelope` / `ErrorEnvelope` as JSON — becomes `structuredContent` and
    /// the text content block, so the MCP and CLI surfaces share one schema doc.
    var envelope: JSONValue
    var isError: Bool
    /// Extra content blocks emitted before the envelope text (e.g. the screenshot
    /// image block).
    var extraContent: [JSONValue] = []
}

struct MCPTool {
    var name: String
    var description: String
    var inputSchema: JSONValue
    var handler: (JSONValue) async throws -> MCPToolOutcome
}

/// Maps MCP tool calls 1:1 onto the warm `ScreenCommanderEngine`. Tool results reuse
/// the CLI's envelope types verbatim; `ScreenCommanderError`s become error envelopes
/// with `isError: true` (protocol-level failures are the server's job, not ours).
final class MCPToolRegistry {
    private let engine: ScreenCommanderEngine
    private let doctor: DoctorReporting
    private(set) var tools: [MCPTool] = []

    /// Events buffered per observe_wait call before older ones are dropped.
    static let observeEventCap = 500

    init(engine: ScreenCommanderEngine, doctor: DoctorReporting) {
        self.engine = engine
        self.doctor = doctor
        tools = buildTools()
    }

    func listToolsResult() -> JSONValue {
        .object([
            "tools": .array(tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema,
                ])
            })
        ])
    }

    /// Runs a tool. Returns nil for an unknown tool name (the server answers with a
    /// JSON-RPC invalid-params error).
    func call(name: String, arguments: JSONValue) async -> MCPToolOutcome? {
        guard let tool = tools.first(where: { $0.name == name }) else {
            return nil
        }
        do {
            return try await tool.handler(arguments)
        } catch let error as ScreenCommanderError {
            return errorOutcome(command: name, error: error)
        } catch {
            return errorOutcome(
                command: name,
                error: .invalidArguments(error.localizedDescription)
            )
        }
    }

    // MARK: - Envelope plumbing

    private func okOutcome<Result: Encodable>(
        command: String,
        result: Result,
        extraContent: [JSONValue] = []
    ) throws -> MCPToolOutcome {
        let envelope = CommandEnvelope(status: "ok", command: command, result: result, exitCode: 0)
        return MCPToolOutcome(
            envelope: try JSONValue(encoding: envelope),
            isError: false,
            extraContent: extraContent
        )
    }

    private func errorOutcome(command: String, error: ScreenCommanderError) -> MCPToolOutcome {
        let envelope = ErrorEnvelope(
            status: "error",
            command: command,
            error: ErrorDetail(code: error.stableCode, message: error.description),
            exitCode: error.exitCode
        )
        let value = (try? JSONValue(encoding: envelope))
            ?? .object(["status": .string("error"), "command": .string(command)])
        return MCPToolOutcome(envelope: value, isError: true)
    }

    // MARK: - Tools

    private func buildTools() -> [MCPTool] {
        [
            screenshotTool(),
            clickTool(),
            typeTool(),
            keyTool(),
            keysTool(),
            scrollTool(),
            dragTool(),
            moveTool(),
            elementsTool(),
            windowsTool(),
            focusTool(),
            observeWaitTool(),
            doctorTool(),
            cleanupTool(),
        ]
    }

    private func screenshotTool() -> MCPTool {
        MCPTool(
            name: "screenshot",
            description: "Capture a display (default: main) or a single window. Returns the image as an in-band content block plus the capture metadata (coordinate mapping source of truth).",
            inputSchema: objectSchema([
                "display": stringProp("Display to capture: 'main' or a numeric display ID. Ignored when 'window' is set."),
                "window": stringProp("Capture one window instead: window ID or app name."),
                "path": stringProp("Output file path; defaults to the managed captures directory."),
                "format": enumProp("Image format.", values: ["png", "jpeg"]),
                "includeCursor": boolProp("Include the cursor in the capture."),
                "updateLastMetadata": boolProp("Update last-screenshot.json so later coordinate actions map against this capture (default true)."),
            ])
        ) { [engine] args in
            let format = try Self.enumArg(args, "format", ImageFormat.self) ?? .png
            let request = ScreenshotRequest(
                displayIdentifier: Self.stringArg(args, "display") ?? "main",
                outputPath: Self.stringArg(args, "path"),
                format: format,
                metadataPath: nil,
                includeCursor: Self.boolArg(args, "includeCursor") ?? false,
                updateLastMetadata: Self.boolArg(args, "updateLastMetadata") ?? true,
                windowIdentifier: Self.stringArg(args, "window")
            )
            let result = try await engine.screenshot(request)

            var extra: [JSONValue] = []
            if let image = result.image, let encoded = try? Self.imageData(from: image, format: format) {
                extra.append(.object([
                    "type": .string("image"),
                    "data": .string(encoded.base64EncodedString()),
                    "mimeType": .string(format == .png ? "image/png" : "image/jpeg"),
                ]))
            }
            return try self.okOutcome(command: "screenshot", result: result, extraContent: extra)
        }
    }

    private func clickTool() -> MCPTool {
        MCPTool(
            name: "click",
            description: "Click at a coordinate (mapped through screenshot metadata) or on an element resolved fresh from the AX tree. Element clicks try delivery tiers ax → pid → global; noCursor never moves the real pointer.",
            inputSchema: objectSchema([
                "x": numberProp("X coordinate (with 'y'); omit when targeting an element."),
                "y": numberProp("Y coordinate."),
                "space": enumProp("Coordinate space for x/y.", values: ["pixels", "points", "normalized"]),
                "meta": stringProp("Screenshot metadata path; defaults to last-screenshot.json."),
                "button": enumProp("Mouse button.", values: ["left", "right", "middle"]),
                "double": boolProp("Double-click."),
                "triple": boolProp("Triple-click."),
                "prime": boolProp("Post a priming mouse-move before clicking."),
                "raw": boolProp("Disable human-like cursor priming and target-app activation."),
                "modifiers": arrayProp("Modifier keys held during the click.", itemType: "string"),
                "element": stringProp("Element title/label substring (alternative to x/y)."),
                "elementId": stringProp("Element id from the elements tool."),
                "role": stringProp("Role filter to disambiguate 'element' matches."),
                "app": stringProp("App owning the element (name or pid); defaults to the frontmost app."),
                "via": enumProp("Force one delivery tier.", values: ["ax", "pid", "global"]),
                "noCursor": boolProp("Never fall back to global delivery (real cursor stays put)."),
                "strict": boolProp("Tier downgrades become errors."),
                "verifyTarget": boolProp("Hit-test the mapped point and include the element found there (coordinate clicks only)."),
            ])
        ) { [engine] args in
            let request = ClickRequest(
                x: try Self.doubleArg(args, "x"),
                y: try Self.doubleArg(args, "y"),
                coordinateSpace: try Self.enumArg(args, "space", CoordinateSpace.self) ?? .pixels,
                metadataPath: Self.stringArg(args, "meta"),
                button: try Self.enumArg(args, "button", MouseButtonChoice.self) ?? .left,
                doubleClick: Self.boolArg(args, "double") ?? false,
                triple: Self.boolArg(args, "triple") ?? false,
                primeClick: Self.boolArg(args, "prime") ?? false,
                humanLike: !(Self.boolArg(args, "raw") ?? false),
                modifiers: try Self.stringArrayArg(args, "modifiers") ?? [],
                element: Self.stringArg(args, "element"),
                elementID: Self.stringArg(args, "elementId"),
                role: Self.stringArg(args, "role"),
                appIdentifier: Self.stringArg(args, "app"),
                via: try Self.enumArg(args, "via", InputDeliveryMethod.self),
                noCursor: Self.boolArg(args, "noCursor") ?? false,
                strict: Self.boolArg(args, "strict") ?? false,
                verifyTarget: Self.boolArg(args, "verifyTarget") ?? false
            )
            let result = try await engine.click(request)
            return try self.okOutcome(command: "click", result: ActionResultEnvelope(action: result))
        }
    }

    private func typeTool() -> MCPTool {
        MCPTool(
            name: "type",
            description: "Type text into the focused control, or into an element (tier ax writes AXValue directly; fallback focuses the element and uses the keyboard path).",
            inputSchema: objectSchema([
                "text": stringProp("Text to type."),
                "delayMs": numberProp("Per-character delay for unicode mode."),
                "mode": enumProp("Input mode.", values: ["paste", "unicode"]),
                "element": stringProp("Target element title/label substring."),
                "elementId": stringProp("Element id from the elements tool."),
                "role": stringProp("Role filter for 'element' matches."),
                "app": stringProp("App owning the element; defaults to the frontmost app."),
                "via": enumProp("Force one delivery tier.", values: ["ax", "global"]),
                "strict": boolProp("Tier downgrades become errors."),
            ], required: ["text"])
        ) { [engine] args in
            let request = TypeRequest(
                text: try Self.requireString(args, "text"),
                delayMilliseconds: try Self.intArg(args, "delayMs"),
                inputMode: try Self.enumArg(args, "mode", TextInputMode.self) ?? .paste,
                element: Self.stringArg(args, "element"),
                elementID: Self.stringArg(args, "elementId"),
                role: Self.stringArg(args, "role"),
                appIdentifier: Self.stringArg(args, "app"),
                via: try Self.enumArg(args, "via", InputDeliveryMethod.self),
                strict: Self.boolArg(args, "strict") ?? false
            )
            let result = try await engine.type(request)
            return try self.okOutcome(command: "type", result: ActionResultEnvelope(action: result))
        }
    }

    private func keyTool() -> MCPTool {
        MCPTool(
            name: "key",
            description: "Press a single key chord, e.g. 'cmd+shift+t' or 'return'.",
            inputSchema: objectSchema([
                "chord": stringProp("Key chord to press."),
            ], required: ["chord"])
        ) { [engine] args in
            let result = try engine.key(KeyRequest(chord: try Self.requireString(args, "chord")))
            return try self.okOutcome(command: "key", result: ActionResultEnvelope(action: result))
        }
    }

    private func keysTool() -> MCPTool {
        MCPTool(
            name: "keys",
            description: "Run a sequence of key steps: 'press:<key>', 'down:<key>', 'up:<key>', 'sleep:<ms>'.",
            inputSchema: objectSchema([
                "steps": arrayProp("Key steps in order.", itemType: "string"),
            ], required: ["steps"])
        ) { [engine] args in
            guard let steps = try Self.stringArrayArg(args, "steps"), !steps.isEmpty else {
                throw ScreenCommanderError.invalidArguments("'steps' must be a non-empty array of strings.")
            }
            let result = try engine.keys(KeysRequest(steps: steps))
            return try self.okOutcome(command: "keys", result: ActionResultEnvelope(action: result))
        }
    }

    private func scrollTool() -> MCPTool {
        MCPTool(
            name: "scroll",
            description: "Scroll at a coordinate or over an element (element scrolls deliver pid → global; there is no AX scroll action).",
            inputSchema: objectSchema([
                "x": numberProp("X coordinate (with 'y'); omit when targeting an element."),
                "y": numberProp("Y coordinate."),
                "dx": numberProp("Horizontal scroll amount."),
                "dy": numberProp("Vertical scroll amount."),
                "unit": enumProp("Scroll unit.", values: ["lines", "pixels"]),
                "space": enumProp("Coordinate space for x/y.", values: ["pixels", "points", "normalized"]),
                "meta": stringProp("Screenshot metadata path; defaults to last-screenshot.json."),
                "element": stringProp("Target element title/label substring."),
                "elementId": stringProp("Element id from the elements tool."),
                "role": stringProp("Role filter for 'element' matches."),
                "app": stringProp("App owning the element; defaults to the frontmost app."),
                "via": enumProp("Force one delivery tier.", values: ["pid", "global"]),
                "noCursor": boolProp("Never fall back to global delivery."),
                "strict": boolProp("Tier downgrades become errors."),
            ])
        ) { [engine] args in
            let request = ScrollRequest(
                x: try Self.doubleArg(args, "x"),
                y: try Self.doubleArg(args, "y"),
                coordinateSpace: try Self.enumArg(args, "space", CoordinateSpace.self) ?? .pixels,
                metadataPath: Self.stringArg(args, "meta"),
                dx: try Self.int32Arg(args, "dx") ?? 0,
                dy: try Self.int32Arg(args, "dy") ?? 0,
                unit: try Self.enumArg(args, "unit", ScrollUnit.self) ?? .lines,
                element: Self.stringArg(args, "element"),
                elementID: Self.stringArg(args, "elementId"),
                role: Self.stringArg(args, "role"),
                appIdentifier: Self.stringArg(args, "app"),
                via: try Self.enumArg(args, "via", InputDeliveryMethod.self),
                noCursor: Self.boolArg(args, "noCursor") ?? false,
                strict: Self.boolArg(args, "strict") ?? false
            )
            let result = try await engine.scroll(request)
            return try self.okOutcome(command: "scroll", result: ActionResultEnvelope(action: result))
        }
    }

    private func dragTool() -> MCPTool {
        MCPTool(
            name: "drag",
            description: "Drag from one coordinate to another with interpolated mouse-drag events.",
            inputSchema: objectSchema([
                "x1": numberProp("Start X."),
                "y1": numberProp("Start Y."),
                "x2": numberProp("End X."),
                "y2": numberProp("End Y."),
                "space": enumProp("Coordinate space.", values: ["pixels", "points", "normalized"]),
                "meta": stringProp("Screenshot metadata path; defaults to last-screenshot.json."),
                "button": enumProp("Mouse button.", values: ["left", "right", "middle"]),
                "steps": numberProp("Interpolated move count (default 12)."),
                "durationMs": numberProp("Total drag duration in ms (default 300)."),
            ], required: ["x1", "y1", "x2", "y2"])
        ) { [engine] args in
            let request = DragRequest(
                x1: try Self.requireDouble(args, "x1"),
                y1: try Self.requireDouble(args, "y1"),
                x2: try Self.requireDouble(args, "x2"),
                y2: try Self.requireDouble(args, "y2"),
                coordinateSpace: try Self.enumArg(args, "space", CoordinateSpace.self) ?? .pixels,
                metadataPath: Self.stringArg(args, "meta"),
                button: try Self.enumArg(args, "button", MouseButtonChoice.self) ?? .left,
                steps: try Self.intArg(args, "steps") ?? 12,
                durationMS: try Self.intArg(args, "durationMs") ?? 300
            )
            let result = try engine.drag(request)
            return try self.okOutcome(command: "drag", result: ActionResultEnvelope(action: result))
        }
    }

    private func moveTool() -> MCPTool {
        MCPTool(
            name: "move",
            description: "Move the cursor to a coordinate (hover), optionally dwelling there.",
            inputSchema: objectSchema([
                "x": numberProp("X coordinate."),
                "y": numberProp("Y coordinate."),
                "space": enumProp("Coordinate space.", values: ["pixels", "points", "normalized"]),
                "meta": stringProp("Screenshot metadata path; defaults to last-screenshot.json."),
                "dwellMs": numberProp("Milliseconds to dwell after moving (default 0)."),
            ], required: ["x", "y"])
        ) { [engine] args in
            let request = MoveRequest(
                x: try Self.requireDouble(args, "x"),
                y: try Self.requireDouble(args, "y"),
                coordinateSpace: try Self.enumArg(args, "space", CoordinateSpace.self) ?? .pixels,
                metadataPath: Self.stringArg(args, "meta"),
                dwellMS: try Self.intArg(args, "dwellMs") ?? 0
            )
            let result = try engine.move(request)
            return try self.okOutcome(command: "move", result: ActionResultEnvelope(action: result))
        }
    }

    private func elementsTool() -> MCPTool {
        MCPTool(
            name: "elements",
            description: "Read an app's accessibility tree: roles, titles, values, enabled state, and bounds (pixel bounds map against the last screenshot). The text-only fast path for reading the screen without a capture.",
            inputSchema: objectSchema([
                "app": stringProp("App name or pid; defaults to the frontmost app."),
                "windowId": numberProp("Restrict to one window id."),
                "allWindows": boolProp("Traverse all of the app's windows."),
                "text": boolProp("Include the indented text-only rendering."),
                "maxDepth": numberProp("Traversal depth limit (default 40)."),
                "maxElements": numberProp("Element cap (default 2000)."),
                "roles": arrayProp("Only include these roles.", itemType: "string"),
                "visibleOnly": boolProp("Skip elements without an on-screen frame."),
                "maxValueLength": numberProp("Truncate element values to this length (default 200)."),
            ])
        ) { [engine] args in
            let request = ElementsRequest(
                appIdentifier: Self.stringArg(args, "app"),
                windowID: try Self.uint32Arg(args, "windowId"),
                allWindows: Self.boolArg(args, "allWindows") ?? false,
                includeText: Self.boolArg(args, "text") ?? false,
                maxDepth: try Self.intArg(args, "maxDepth") ?? 40,
                maxElements: try Self.intArg(args, "maxElements") ?? 2000,
                roles: try Self.stringArrayArg(args, "roles"),
                visibleOnly: Self.boolArg(args, "visibleOnly") ?? false,
                maxValueLength: try Self.intArg(args, "maxValueLength") ?? 200
            )
            let result = try await engine.elements(request)
            return try self.okOutcome(command: "elements", result: result)
        }
    }

    private func windowsTool() -> MCPTool {
        MCPTool(
            name: "windows",
            description: "List on-screen windows (id, title, app, bounds in points, layer).",
            inputSchema: objectSchema([
                "app": stringProp("Only list windows of this app (name or pid)."),
            ])
        ) { [engine] args in
            let result = try await engine.windows(WindowsRequest(appIdentifier: Self.stringArg(args, "app")))
            return try self.okOutcome(command: "windows", result: result)
        }
    }

    private func focusTool() -> MCPTool {
        MCPTool(
            name: "focus",
            description: "Activate an app (bring it frontmost). Reports the previously frontmost app.",
            inputSchema: objectSchema([
                "app": stringProp("App to activate (name or pid)."),
            ], required: ["app"])
        ) { [engine] args in
            let result = try await engine.focus(FocusRequest(appIdentifier: try Self.requireString(args, "app")))
            return try self.okOutcome(command: "focus", result: result)
        }
    }

    private func observeWaitTool() -> MCPTool {
        MCPTool(
            name: "observe_wait",
            description: "Watch an app's UI-change events (AXObserver push stream) for up to timeoutMs, optionally until a predicate like 'role=AXButton title~=Save' matches. Returns the events seen and the outcome; an unmet 'until' is an observe_timeout error.",
            inputSchema: objectSchema([
                "app": stringProp("App to observe (name or pid)."),
                "events": stringProp("Comma-separated event kinds: value,focus,window,destroy,app. Default: all."),
                "timeoutMs": numberProp("How long to watch, in milliseconds (1–600000)."),
                "until": stringProp("Stop early when an element matching this predicate appears. Keys: role,title,value,id; '=' exact, '~=' contains."),
            ], required: ["app", "timeoutMs"])
        ) { [engine] args in
            let timeout = try Self.requireInt(args, "timeoutMs")
            guard (1...600_000).contains(timeout) else {
                throw ScreenCommanderError.invalidArguments("'timeoutMs' must be between 1 and 600000.")
            }
            let request = ObserveRequest(
                appIdentifier: try Self.requireString(args, "app"),
                kinds: try ObservedEventKind.parseList(Self.stringArg(args, "events")),
                timeoutMS: timeout,
                predicate: try Self.stringArg(args, "until").map(ObservePredicate.parse)
            )

            let collector = ObserveEventCollector(cap: Self.observeEventCap)
            let outcome = try await engine.observe(request) { event in
                collector.append(event)
            }

            if case .timedOutUnmet = outcome {
                return self.errorOutcome(
                    command: "observe_wait",
                    error: .observeTimeout("'until' predicate was not matched within \(timeout) ms.")
                )
            }

            let (events, dropped) = collector.snapshot()
            let result = ObserveWaitResult(
                outcome: Self.describe(outcome),
                matched: {
                    if case .matched(let element) = outcome { return element }
                    return nil
                }(),
                events: events,
                droppedEvents: dropped > 0 ? dropped : nil
            )
            return try self.okOutcome(command: "observe_wait", result: result)
        }
    }

    private func doctorTool() -> MCPTool {
        MCPTool(
            name: "doctor",
            description: "Report permission status (Screen Recording, Accessibility) and active displays.",
            inputSchema: objectSchema([:])
        ) { [doctor] _ in
            try self.okOutcome(command: "doctor", result: try doctor.collect())
        }
    }

    private func cleanupTool() -> MCPTool {
        MCPTool(
            name: "cleanup",
            description: "Prune managed captures older than the given age (default 24 hours).",
            inputSchema: objectSchema([
                "olderThanHours": numberProp("Delete captures older than this many hours."),
            ])
        ) { [engine] args in
            let result = try engine.cleanup(CleanupRequest(olderThanHours: try Self.intArg(args, "olderThanHours")))
            return try self.okOutcome(command: "cleanup", result: result)
        }
    }

    private static func describe(_ outcome: ObserveOutcome) -> String {
        switch outcome {
        case .matched: return "matched"
        case .timedOut: return "timed_out"
        case .timedOutUnmet: return "timed_out_unmet"
        case .interrupted: return "interrupted"
        case .completed: return "completed"
        }
    }

    // MARK: - Argument helpers

    // Absent keys and explicit nulls mean "not provided"; a present value of the
    // wrong shape is an invalid_arguments tool error, never a silent default or a
    // trapping conversion — malformed automation input must not act partially or
    // kill the server.

    private static func stringArg(_ args: JSONValue, _ key: String) -> String? {
        args[key]?.stringValue
    }

    private static func boolArg(_ args: JSONValue, _ key: String) -> Bool? {
        args[key]?.boolValue
    }

    private static func doubleArg(_ args: JSONValue, _ key: String) throws -> Double? {
        guard let value = args[key], value != .null else { return nil }
        guard let number = value.numberValue else {
            throw ScreenCommanderError.invalidArguments("'\(key)' must be a number.")
        }
        return number
    }

    private static func intArg(_ args: JSONValue, _ key: String) throws -> Int? {
        guard let value = args[key], value != .null else { return nil }
        guard let int = value.intValue else {
            throw ScreenCommanderError.invalidArguments("'\(key)' must be an integer.")
        }
        return int
    }

    private static func int32Arg(_ args: JSONValue, _ key: String) throws -> Int32? {
        guard let int = try intArg(args, key) else { return nil }
        guard let narrowed = Int32(exactly: int) else {
            throw ScreenCommanderError.invalidArguments("'\(key)' must be between \(Int32.min) and \(Int32.max).")
        }
        return narrowed
    }

    private static func uint32Arg(_ args: JSONValue, _ key: String) throws -> UInt32? {
        guard let int = try intArg(args, key) else { return nil }
        guard let narrowed = UInt32(exactly: int) else {
            throw ScreenCommanderError.invalidArguments("'\(key)' must be between 0 and \(UInt32.max).")
        }
        return narrowed
    }

    private static func stringArrayArg(_ args: JSONValue, _ key: String) throws -> [String]? {
        guard let value = args[key], value != .null else { return nil }
        guard let array = value.arrayValue else {
            throw ScreenCommanderError.invalidArguments("'\(key)' must be an array of strings.")
        }
        return try array.map { element in
            guard let string = element.stringValue else {
                throw ScreenCommanderError.invalidArguments("'\(key)' must contain only strings.")
            }
            return string
        }
    }

    private static func requireString(_ args: JSONValue, _ key: String) throws -> String {
        guard let value = stringArg(args, key) else {
            throw ScreenCommanderError.invalidArguments("Missing required string argument '\(key)'.")
        }
        return value
    }

    private static func requireDouble(_ args: JSONValue, _ key: String) throws -> Double {
        guard let value = try doubleArg(args, key) else {
            throw ScreenCommanderError.invalidArguments("Missing required number argument '\(key)'.")
        }
        return value
    }

    private static func requireInt(_ args: JSONValue, _ key: String) throws -> Int {
        guard let value = try intArg(args, key) else {
            throw ScreenCommanderError.invalidArguments("Missing required integer argument '\(key)'.")
        }
        return value
    }

    private static func enumArg<T: RawRepresentable>(
        _ args: JSONValue,
        _ key: String,
        _ type: T.Type
    ) throws -> T? where T.RawValue == String {
        guard let raw = stringArg(args, key) else { return nil }
        guard let value = T(rawValue: raw) else {
            throw ScreenCommanderError.invalidArguments("Invalid value '\(raw)' for '\(key)'.")
        }
        return value
    }

    // MARK: - Schema helpers

    private func objectSchema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map(JSONValue.string))
        }
        return .object(schema)
    }

    private func stringProp(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private func numberProp(_ description: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(description)])
    }

    private func boolProp(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private func arrayProp(_ description: String, itemType: String) -> JSONValue {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object(["type": .string(itemType)]),
        ])
    }

    private func enumProp(_ description: String, values: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description),
            "enum": .array(values.map(JSONValue.string)),
        ])
    }

    /// In-memory encode for the screenshot image block, matching the requested
    /// format (the file on disk is written by the engine as usual).
    private static func imageData(from image: CGImage, format: ImageFormat) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            format.utTypeIdentifier,
            1,
            nil
        ) else {
            throw ScreenCommanderError.imageWriteFailed("Could not create in-memory \(format.rawValue) destination.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenCommanderError.imageWriteFailed("Could not encode in-memory \(format.rawValue).")
        }
        return data as Data
    }
}

/// `observe_wait` result payload. Events beyond the cap are dropped oldest-first and
/// counted in `droppedEvents` — no silent truncation.
struct ObserveWaitResult: Encodable {
    var outcome: String
    var matched: AXElementRecord?
    var events: [ObservedEvent]
    var droppedEvents: Int?
}

/// Thread-safe bounded buffer for observed events (`emit` fires from the engine's
/// stream-consuming task).
final class ObserveEventCollector: @unchecked Sendable {
    private let cap: Int
    private let lock = NSLock()
    private var events: [ObservedEvent] = []
    private var dropped = 0

    init(cap: Int) {
        self.cap = cap
    }

    func append(_ event: ObservedEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
        if events.count > cap {
            events.removeFirst(events.count - cap)
            dropped += 1
        }
    }

    func snapshot() -> (events: [ObservedEvent], dropped: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (events, dropped)
    }
}
