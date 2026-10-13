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
        tools = buildTools().map { tool in
            guard Self.actionTools.contains(tool.name), var schema = tool.inputSchema.objectValue,
                  var properties = schema["properties"]?.objectValue else { return tool }
            var tool = tool
            let axOnly = Self.axOnlyTools.contains(tool.name)
            for (key, value) in Self.targetProperties where properties[key] == nil && !(axOnly && key == "foreground") {
                properties[key] = value
            }
            properties["postObserve"] = objectSchema([
                "app": stringProp("App to read after delivery: name or pid."),
                "since": stringProp("snapshotId to return a delta against."),
                "maxElements": numberProp("Maximum elements, 1 to 10000 (default 200)."),
                "maxVisited": numberProp("Maximum nodes visited, 1 to 100000 (default 2000)."),
                "timeoutMs": numberProp("Read deadline in ms, 1 to 60000 (default 500)."),
                "profile": enumProp("Fields to read: full (default) or text.", values: ["full", "text"])
            ], required: ["app"], description: "After delivery, read the app's accessibility tree into result.observation. A failed read sets observationError and leaves the action successful.")
            schema["properties"] = .object(properties)
            tool.inputSchema = .object(schema)
            return tool
        }
    }

    private static let actionTools: Set<String> = [
        "click", "type", "key", "keys", "scroll", "drag", "move", "select_text", "perform_action",
    ]
    /// Action tools that only ever use the AX tier, so `foreground` means nothing.
    private static let axOnlyTools: Set<String> = ["select_text", "perform_action"]

    /// Background-delivery targeting shared by every action tool.
    private static let targetProperties: [String: JSONValue] = [
        "app": .object([
            "type": .string("string"),
            "description": .string("Target app: name or pid. Element input defaults to the frontmost app. Keyboard input defaults to the window of the last window screenshot, else the frontmost app. Coordinates default to the window of the last window screenshot, else whatever is topmost at the point, at any layer."),
        ]),
        "windowId": .object([
            "type": .string("number"),
            "description": .string("Window to send background input to, by ID from the windows tool. Keys go to this window, made key first, and element searches it."),
        ]),
        "foreground": .object([
            "type": .string("boolean"),
            "description": .string("Allow foreground delivery (tier global): post through the HID event tap and activate the target app when it is known. Moves the real cursor and can change focus. The target app is still leased, and the action waits until the user stops typing or moving the mouse. Default false."),
        ]),
        "session": .object([
            "type": .string("string"),
            "description": .string("Agent session that leases the target app during background delivery. While another session holds the app, input fails with target_busy. Default: $SCREENCOMMANDER_SESSION, else this server's serve-<pid>."),
        ]),
        "agentCursor": .object([
            "type": .string("boolean"),
            "description": .string("Draw the agent cursor. Default true unless SCREENCOMMANDER_AGENT_CURSOR=0. The session lease, the focus guard, and yielding to the user apply either way."),
        ]),
    ]

    private static let viaValues = InputDeliveryMethod.allValueStrings

    // Field descriptions shared by several tools, worded as in the CLI help.
    private static let spaceHelp = "Coordinate space: pixels of the screenshot image (default), points, or normalized 0 to 1, all from the screenshot's top-left corner."
    private static let metaHelp = "Screenshot metadata to map coordinates against. Defaults to last-screenshot.json."
    private static let strictMetadataHelp = "Fail with stale_metadata when the screenshot metadata is known to be out of date."
    private static let elementHelp = "Target the element whose title, description, or value matches this text in the app's focused window, or in windowId when given (case-insensitive, exact match before substring)."
    private static let elementIDHelp = "Target an element by its element ID from elements or app_state, such as 0.3.2. Read IDs again after the UI changes."
    private static let roleHelp = "Only match element against this role, such as button or AXButton."
    private static let strictHelp = "Use only the first delivery tier and fail instead of falling back to the next one."

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
            // Validate follow-up options before any side effect. A failed post-read
            // must never turn a successfully delivered action into a retryable error.
            let observation = try postObservationRequest(name: name, arguments: arguments)
            var outcome = try await tool.handler(arguments)
            if let observation, !outcome.isError, var envelope = outcome.envelope.objectValue,
               var result = envelope["result"]?.objectValue {
                do {
                    result["observation"] = try JSONValue(encoding: await engine.elements(observation))
                } catch {
                    result["observationError"] = .string(String(describing: error))
                }
                envelope["result"] = .object(result)
                outcome.envelope = .object(envelope)
            }
            return outcome
        } catch let error as ScreenCommanderError {
            return errorOutcome(command: name, error: error)
        } catch {
            return errorOutcome(
                command: name,
                error: .invalidArguments(error.localizedDescription)
            )
        }
    }

    private func postObservationRequest(name: String, arguments: JSONValue) throws -> ElementsRequest? {
        guard let options = arguments["postObserve"], options != .null else { return nil }
        guard Self.actionTools.contains(name), options.objectValue != nil else {
            throw ScreenCommanderError.invalidArguments("postObserve requires an action tool and an options object.")
        }
        for key in ["profile", "since"] {
            if let value = options[key], value != .null, value.stringValue == nil {
                throw ScreenCommanderError.invalidArguments("postObserve.\(key) must be a string.")
            }
        }
        let app = try Self.requireString(options, "app")
        guard !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScreenCommanderError.invalidArguments("postObserve.app must not be empty.")
        }
        let count = try Self.intArg(options, "maxElements") ?? 200
        let visited = try Self.intArg(options, "maxVisited") ?? 2000
        let timeout = try Self.intArg(options, "timeoutMs") ?? 500
        guard (1...10_000).contains(count), (1...100_000).contains(visited), (1...60_000).contains(timeout) else {
            throw ScreenCommanderError.invalidArguments("Invalid postObserve read budget.")
        }
        return ElementsRequest(appIdentifier: app, maxElements: count,
                               profile: try Self.enumArg(options, "profile", AXTreeOptions.Profile.self) ?? .full,
                               maxVisited: visited, timeoutMS: timeout, snapshot: true,
                               since: Self.stringArg(options, "since"))
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
            appStateTool(),
            selectTextTool(),
            performActionTool(),
            windowsTool(),
            listAppsTool(),
            launchAppTool(),
            focusTool(),
            observeWaitTool(),
            doctorTool(),
            cleanupTool(),
        ]
    }

    private func screenshotTool() -> MCPTool {
        MCPTool(
            name: "screenshot",
            description: "Capture a display or one window. Returns the image as a content block plus its metadata, which becomes last-screenshot.json for coordinate input unless updateLastMetadata is false. Window captures work on windows behind other windows.",
            inputSchema: objectSchema([
                "display": stringProp("Display to capture: 'main' (default) or a display ID from doctor. Ignored with window."),
                "window": stringProp("Capture one window instead: a window ID from the windows tool, or an app name prefix for that app's frontmost window."),
                "path": stringProp("Image path. Defaults to a timestamped file in the managed captures directory."),
                "format": enumProp("Image format (default png).", values: ["png", "jpeg"]),
                "includeCursor": boolProp("Include the cursor in the image."),
                "updateLastMetadata": boolProp("Write last-screenshot.json so later coordinate input maps against this capture (default true)."),
            ])
        ) { [engine] args in
            let format = try Self.enumArg(args, "format", ImageFormat.self) ?? .png
            let request = ScreenshotRequest(
                displayIdentifier: Self.stringArg(args, "display") ?? "main",
                outputPath: Self.stringArg(args, "path"),
                format: format,
                metadataPath: nil,
                includeCursor: try Self.boolArg(args, "includeCursor") ?? false,
                updateLastMetadata: try Self.boolArg(args, "updateLastMetadata") ?? true,
                windowIdentifier: Self.stringArg(args, "window")
            )
            let result = try await engine.screenshot(request)

            var extra: [JSONValue] = []
            if let encoded = result.encodedImageData ?? result.image.flatMap({ try? Self.imageData(from: $0, format: format) }) {
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
            description: "Click at screenshot coordinates or on an element, in the background by default. An element with a plain left or right click is pressed through accessibility (tier ax). Otherwise mouse events go to the target window (tiers window and focusAssisted, in the app profile's order). None of these activate the app or move the user's cursor. foreground: true allows tier global. The result reports deliveryMethod and a focus receipt.",
            inputSchema: objectSchema([
                "x": numberProp("X coordinate in space units. Omit with element or elementId."),
                "y": numberProp("Y coordinate in space units."),
                "space": enumProp(Self.spaceHelp, values: ["pixels", "points", "normalized"]),
                "meta": stringProp(Self.metaHelp),
                "button": enumProp("Mouse button (default left).", values: ["left", "right", "middle"]),
                "double": boolProp("Double-click."),
                "triple": boolProp("Triple-click."),
                "raw": boolProp("Skip the pointer move and short pause sent before the click. With foreground, also skip activating the target app."),
                "modifiers": arrayProp("Modifier keys to hold during the click: cmd, shift, option, ctrl.", itemType: "string"),
                "element": stringProp(Self.elementHelp),
                "elementId": stringProp(Self.elementIDHelp),
                "role": stringProp(Self.roleHelp),
                "via": enumProp("Use only this delivery tier, with no fallback. ax needs element or elementId. global needs foreground.", values: Self.viaValues),
                "noCursor": boolProp("Deprecated. No effect."),
                "strict": boolProp(Self.strictHelp),
                "verifyTarget": boolProp("Before a coordinate click, read the accessibility element at the point and report it as verifiedTarget. The click happens either way."),
                "strictMetadata": boolProp(Self.strictMetadataHelp),
            ])
        ) { [engine] args in
            let request = ClickRequest(
                x: try Self.doubleArg(args, "x"),
                y: try Self.doubleArg(args, "y"),
                coordinateSpace: try Self.enumArg(args, "space", CoordinateSpace.self) ?? .pixels,
                metadataPath: Self.stringArg(args, "meta"),
                button: try Self.enumArg(args, "button", MouseButtonChoice.self) ?? .left,
                doubleClick: try Self.boolArg(args, "double") ?? false,
                triple: try Self.boolArg(args, "triple") ?? false,
                // `prime` was removed in 0.6.0. A client that still sends it is not refused.
                primeClick: false,
                humanLike: !(try Self.boolArg(args, "raw") ?? false),
                modifiers: try Self.stringArrayArg(args, "modifiers") ?? [],
                element: Self.stringArg(args, "element"),
                elementID: Self.stringArg(args, "elementId"),
                role: Self.stringArg(args, "role"),
                appIdentifier: Self.stringArg(args, "app"),
                via: try Self.viaArg(args),
                noCursor: try Self.boolArg(args, "noCursor") ?? false,
                strict: try Self.boolArg(args, "strict") ?? false,
                verifyTarget: try Self.boolArg(args, "verifyTarget") ?? false,
                strictMetadata: try Self.boolArg(args, "strictMetadata") ?? false,
                windowID: try Self.uint32Arg(args, "windowId"),
                foreground: try Self.boolArg(args, "foreground") ?? false,
                session: Self.stringArg(args, "session"),
                agentCursor: try Self.boolArg(args, "agentCursor")
            )
            let result = try await engine.click(request)
            return try self.okOutcome(command: "click", result: ActionResultEnvelope(action: result))
        }
    }

    private func typeTool() -> MCPTool {
        MCPTool(
            name: "type",
            description: "Type text into an app, in the background by default. Text goes in through accessibility first (tier ax), at the caret of the element or of the app's focused text field, and is read back to set verified. Otherwise it goes as Unicode key events (tiers window and focusAssisted). Chromium and Electron apps get key events first. The clipboard is used only with mode paste and foreground: true.",
            inputSchema: objectSchema([
                "text": stringProp("Text to type."),
                "delayMs": numberProp("Delay between key events in milliseconds, 0 to 10000."),
                "mode": enumProp("How key events enter the text: unicode (default, one key event per character) or paste (the clipboard and cmd+v, used only with foreground).", values: ["paste", "unicode"]),
                "replace": boolProp("Replace the field's whole value instead of inserting at the caret. Needs an element or a focused text field."),
                "element": stringProp(Self.elementHelp),
                "elementId": stringProp(Self.elementIDHelp),
                "role": stringProp(Self.roleHelp),
                "via": enumProp("Use only this delivery tier, with no fallback. ax needs an element or a focused text field. global needs foreground.", values: Self.viaValues),
                "strict": boolProp(Self.strictHelp),
            ], required: ["text"])
        ) { [engine] args in
            let request = TypeRequest(
                text: try Self.requireString(args, "text"),
                delayMilliseconds: try Self.intArg(args, "delayMs"),
                inputMode: try Self.enumArg(args, "mode", TextInputMode.self) ?? .unicode,
                element: Self.stringArg(args, "element"),
                elementID: Self.stringArg(args, "elementId"),
                role: Self.stringArg(args, "role"),
                appIdentifier: Self.stringArg(args, "app"),
                via: try Self.viaArg(args),
                strict: try Self.boolArg(args, "strict") ?? false,
                windowID: try Self.uint32Arg(args, "windowId"),
                foreground: try Self.boolArg(args, "foreground") ?? false,
                session: Self.stringArg(args, "session"),
                agentCursor: try Self.boolArg(args, "agentCursor"),
                replace: try Self.boolArg(args, "replace") ?? false
            )
            let result = try await engine.type(request)
            return try self.okOutcome(command: "type", result: ActionResultEnvelope(action: result))
        }
    }

    private func keyTool() -> MCPTool {
        MCPTool(
            name: "key",
            description: "Press one key chord in an app, in the background by default. A Command chord that matches a menu item is pressed through accessibility, and menuItem names it. Other chords go as key events, and Command chords need an on-screen window, made key without raising it (tier focusAssisted). System keys (volumeup, mute, playpause, launchpad, and the like), the spotlight and missioncontrol shortcuts, and chords macOS handles before any app (cmd+tab, cmd+shift+tab, cmd+space, cmd+option+space, cmd+option+esc, cmd+ctrl+q, cmd+shift+q, and the cmd+shift+3, 4, and 5 screenshot chords) need foreground: true.",
            inputSchema: objectSchema([
                "chord": stringProp("Modifiers and one key joined by +, such as cmd+a, shift+tab, or return. Modifiers: cmd, shift, option, ctrl, fn."),
            ], required: ["chord"])
        ) { [engine] args in
            let request = KeyRequest(
                chord: try Self.requireString(args, "chord"),
                appIdentifier: Self.stringArg(args, "app"),
                windowID: try Self.uint32Arg(args, "windowId"),
                foreground: try Self.boolArg(args, "foreground") ?? false,
                session: Self.stringArg(args, "session"),
                agentCursor: try Self.boolArg(args, "agentCursor")
            )
            let result = try await engine.key(request)
            return try self.okOutcome(command: "key", result: ActionResultEnvelope(action: result))
        }
    }

    private func keysTool() -> MCPTool {
        MCPTool(
            name: "keys",
            description: "Press, hold, and release keys in order, in the background by default. Steps that hold Command need an on-screen window, made key without raising it (tier focusAssisted). System keys need foreground: true.",
            inputSchema: objectSchema([
                "steps": arrayProp("Steps as <action>:<key>: down:<key> holds a key, up:<key> releases it, press:<chord> presses a chord, sleep:<ms> waits.", itemType: "string"),
            ], required: ["steps"])
        ) { [engine] args in
            guard let steps = try Self.stringArrayArg(args, "steps"), !steps.isEmpty else {
                throw ScreenCommanderError.invalidArguments("'steps' must be a non-empty array of strings.")
            }
            let request = KeysRequest(
                steps: steps,
                appIdentifier: Self.stringArg(args, "app"),
                windowID: try Self.uint32Arg(args, "windowId"),
                foreground: try Self.boolArg(args, "foreground") ?? false,
                session: Self.stringArg(args, "session"),
                agentCursor: try Self.boolArg(args, "agentCursor")
            )
            let result = try await engine.keys(request)
            return try self.okOutcome(command: "keys", result: ActionResultEnvelope(action: result))
        }
    }

    private func scrollTool() -> MCPTool {
        MCPTool(
            name: "scroll",
            description: "Scroll at screenshot coordinates or over an element, in the background by default. Wheel events go to the target window (tiers window and focusAssisted, in the app profile's order). direction scrolls an element by pages, first through its page actions or scroll bar in accessibility (tier ax). foreground: true allows tier global.",
            inputSchema: objectSchema([
                "x": numberProp("X coordinate in space units. Omit with element or elementId."),
                "y": numberProp("Y coordinate in space units."),
                "dx": numberProp("Horizontal amount in unit. Positive scrolls left."),
                "dy": numberProp("Vertical amount in unit. Positive scrolls up."),
                "unit": enumProp("Unit of dx and dy (default lines).", values: ["lines", "pixels"]),
                "space": enumProp(Self.spaceHelp, values: ["pixels", "points", "normalized"]),
                "meta": stringProp(Self.metaHelp),
                "element": stringProp(Self.elementHelp),
                "elementId": stringProp(Self.elementIDHelp),
                "role": stringProp(Self.roleHelp),
                "direction": enumProp("Scroll an element by pages in this direction, instead of dx and dy. Needs element or elementId.", values: ScrollDirection.allCases.map(\.rawValue)),
                "pages": numberProp("Pages to scroll with direction, 1 to 50 (default 1)."),
                "via": enumProp("Use only this delivery tier, with no fallback. ax needs direction. global needs foreground.", values: Self.viaValues),
                "noCursor": boolProp("Deprecated. No effect."),
                "strict": boolProp(Self.strictHelp),
                "strictMetadata": boolProp(Self.strictMetadataHelp),
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
                via: try Self.viaArg(args),
                noCursor: try Self.boolArg(args, "noCursor") ?? false,
                strict: try Self.boolArg(args, "strict") ?? false,
                strictMetadata: try Self.boolArg(args, "strictMetadata") ?? false,
                windowID: try Self.uint32Arg(args, "windowId"),
                foreground: try Self.boolArg(args, "foreground") ?? false,
                session: Self.stringArg(args, "session"),
                agentCursor: try Self.boolArg(args, "agentCursor"),
                direction: try Self.enumArg(args, "direction", ScrollDirection.self),
                pages: try Self.intArg(args, "pages") ?? 1
            )
            let result = try await engine.scroll(request)
            return try self.okOutcome(command: "scroll", result: ActionResultEnvelope(action: result))
        }
    }

    private func dragTool() -> MCPTool {
        MCPTool(
            name: "drag",
            description: "Drag between two screenshot coordinates, in the background by default. The drag goes to the window under the start point (tiers window and focusAssisted) without activating the app or moving the user's cursor. foreground: true uses tier global.",
            inputSchema: objectSchema([
                "x1": numberProp("Start X coordinate in space units."),
                "y1": numberProp("Start Y coordinate in space units."),
                "x2": numberProp("End X coordinate in space units."),
                "y2": numberProp("End Y coordinate in space units."),
                "space": enumProp(Self.spaceHelp, values: ["pixels", "points", "normalized"]),
                "meta": stringProp(Self.metaHelp),
                "button": enumProp("Mouse button (default left).", values: ["left", "right", "middle"]),
                "steps": numberProp("Number of intermediate drag events, 1 to 10000 (default 12)."),
                "durationMs": numberProp("Total drag time in milliseconds, 0 to 60000 (default 300)."),
                "strictMetadata": boolProp(Self.strictMetadataHelp),
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
                durationMS: try Self.intArg(args, "durationMs") ?? 300,
                strictMetadata: try Self.boolArg(args, "strictMetadata") ?? false,
                appIdentifier: Self.stringArg(args, "app"),
                windowID: try Self.uint32Arg(args, "windowId"),
                foreground: try Self.boolArg(args, "foreground") ?? false,
                session: Self.stringArg(args, "session"),
                agentCursor: try Self.boolArg(args, "agentCursor")
            )
            let result = try await engine.drag(request)
            return try self.okOutcome(command: "drag", result: ActionResultEnvelope(action: result))
        }
    }

    private func moveTool() -> MCPTool {
        MCPTool(
            name: "move",
            description: "Hover at screenshot coordinates, in the background by default. Sends a pointer move to the window under the point (tiers window and focusAssisted) without moving the user's cursor. foreground: true uses tier global and moves the real cursor.",
            inputSchema: objectSchema([
                "x": numberProp("X coordinate in space units."),
                "y": numberProp("Y coordinate in space units."),
                "space": enumProp(Self.spaceHelp, values: ["pixels", "points", "normalized"]),
                "meta": stringProp(Self.metaHelp),
                "dwellMs": numberProp("Wait this many milliseconds after the move, 0 to 60000 (default 0)."),
                "strictMetadata": boolProp(Self.strictMetadataHelp),
            ], required: ["x", "y"])
        ) { [engine] args in
            let request = MoveRequest(
                x: try Self.requireDouble(args, "x"),
                y: try Self.requireDouble(args, "y"),
                coordinateSpace: try Self.enumArg(args, "space", CoordinateSpace.self) ?? .pixels,
                metadataPath: Self.stringArg(args, "meta"),
                dwellMS: try Self.intArg(args, "dwellMs") ?? 0,
                strictMetadata: try Self.boolArg(args, "strictMetadata") ?? false,
                appIdentifier: Self.stringArg(args, "app"),
                windowID: try Self.uint32Arg(args, "windowId"),
                foreground: try Self.boolArg(args, "foreground") ?? false,
                session: Self.stringArg(args, "session"),
                agentCursor: try Self.boolArg(args, "agentCursor")
            )
            let result = try await engine.move(request)
            return try self.okOutcome(command: "move", result: ActionResultEnvelope(action: result))
        }
    }

    private func elementsTool() -> MCPTool {
        MCPTool(
            name: "elements",
            description: "Read an app's accessibility tree without activating it or capturing pixels: roles, text, state, actions, element IDs, and bounds. boundsPixels maps into the last screenshot. Element IDs are tree positions, so read again after the UI changes.",
            inputSchema: objectSchema([
                "app": stringProp("Target app: name or pid. Defaults to the frontmost app."),
                "windowId": numberProp("Read only this window, by ID from the windows tool."),
                "allWindows": boolProp("Read every window of the app instead of only the focused one."),
                "text": boolProp("Also render an indented text view, one line per element with text."),
                "maxDepth": numberProp("Maximum tree depth, 1 to 200 (default 40)."),
                "maxElements": numberProp("Maximum elements, 1 to 10000 (default 2000). The result is marked truncated at the limit."),
                "roles": arrayProp("Only return these roles, such as AXButton or button.", itemType: "string"),
                "visibleOnly": boolProp("Only return elements whose frame intersects their window."),
                "maxValueLength": numberProp("Cut element values longer than this many characters (default 200)."),
                "profile": enumProp("Fields to read: full (default) or text (skips bounds and actions).", values: ["full", "text"]),
                "maxVisited": numberProp("Stop after visiting this many nodes, 1 to 100000. The result then reports partialReason."),
                "timeoutMs": numberProp("Stop reading after this many milliseconds, 1 to 60000. The result then reports partialReason."),
                "snapshot": boolProp("Keep this read as a snapshot and return its snapshotId."),
                "since": stringProp("Return only changed elements and removedIds since this snapshotId. A missing or incompatible snapshot returns the full tree with resetReason."),
            ])
        ) { [engine] args in
            let request = ElementsRequest(
                appIdentifier: Self.stringArg(args, "app"),
                windowID: try Self.uint32Arg(args, "windowId"),
                allWindows: try Self.boolArg(args, "allWindows") ?? false,
                includeText: try Self.boolArg(args, "text") ?? false,
                maxDepth: try Self.intArg(args, "maxDepth") ?? 40,
                maxElements: try Self.intArg(args, "maxElements") ?? 2000,
                roles: try Self.stringArrayArg(args, "roles"),
                visibleOnly: try Self.boolArg(args, "visibleOnly") ?? false,
                maxValueLength: try Self.intArg(args, "maxValueLength") ?? 200,
                profile: try Self.enumArg(args, "profile", AXTreeOptions.Profile.self) ?? .full,
                maxVisited: try Self.intArg(args, "maxVisited"),
                timeoutMS: try Self.intArg(args, "timeoutMs"),
                snapshot: try Self.boolArg(args, "snapshot") ?? false,
                since: Self.stringArg(args, "since")
            )
            let result = try await engine.elements(request)
            return try self.okOutcome(command: "elements", result: result)
        }
    }

    private func appStateTool() -> MCPTool {
        MCPTool(
            name: "app_state",
            description: "Capture an app's window and read its accessibility tree in one call, without activating the app. Works on windows behind other windows. The image comes back as a content block and becomes last-screenshot.json for coordinate input. Element IDs match the elements tool. After the first call for a window, the tree is a delta (changed elements and removedIds) against the previous call. Pass full: true for the whole tree.",
            inputSchema: objectSchema([
                "app": stringProp("Target app: name or pid."),
                "windowId": numberProp("Window to capture and read, by ID from the windows tool. Defaults to the app's frontmost window."),
                "maxDepth": numberProp("Maximum tree depth, 1 to 200 (default 40)."),
                "maxElements": numberProp("Maximum elements, 1 to 10000 (default 2000)."),
                "text": boolProp("Also render an indented text view of the returned elements."),
                "format": enumProp("Image format (default png).", values: ["png", "jpeg"]),
                "full": boolProp("Return the whole tree even when an earlier snapshot exists. It still becomes the new baseline."),
                "since": stringProp("Return a delta against this snapshotId instead of the previous call for the window."),
            ], required: ["app"])
        ) { [engine] args in
            let format = try Self.enumArg(args, "format", ImageFormat.self) ?? .png
            let full = try Self.boolArg(args, "full") ?? false
            let request = AppStateRequest(
                appIdentifier: try Self.requireString(args, "app"),
                windowID: try Self.uint32Arg(args, "windowId"),
                maxDepth: try Self.intArg(args, "maxDepth") ?? 40,
                maxElements: try Self.intArg(args, "maxElements") ?? 2000,
                includeText: try Self.boolArg(args, "text") ?? false,
                format: format,
                diff: true,
                since: full ? nil : Self.stringArg(args, "since"),
                fullTree: full
            )
            let result = try await engine.appState(request)

            var extra: [JSONValue] = []
            if let encoded = result.encodedImageData ?? result.image.flatMap({ try? Self.imageData(from: $0, format: format) }) {
                extra.append(.object([
                    "type": .string("image"),
                    "data": .string(encoded.base64EncodedString()),
                    "mimeType": .string(format == .png ? "image/png" : "image/jpeg"),
                ]))
            }
            return try self.okOutcome(command: "app_state", result: result, extraContent: extra)
        }
    }

    private func selectTextTool() -> MCPTool {
        MCPTool(
            name: "select_text",
            description: "Select text in an element through accessibility (tier ax), by UTF-16 range or by the first match of text, without activating the app. The selection is read back to set verified. Pass location and length, or text.",
            inputSchema: objectSchema([
                "element": stringProp(Self.elementHelp),
                "elementId": stringProp(Self.elementIDHelp),
                "role": stringProp(Self.roleHelp),
                "location": numberProp("Range start in UTF-16 code units. Pass with length."),
                "length": numberProp("Range length in UTF-16 code units. Pass with location."),
                "text": stringProp("Select the first occurrence of this text, matching case first and then ignoring case."),
            ])
        ) { [engine] args in
            let location = try Self.intArg(args, "location")
            let length = try Self.intArg(args, "length")
            guard (location == nil) == (length == nil) else {
                throw ScreenCommanderError.invalidArguments("Pass 'location' and 'length' together.")
            }
            let request = SelectTextRequest(
                element: Self.stringArg(args, "element"),
                elementID: Self.stringArg(args, "elementId"),
                role: Self.stringArg(args, "role"),
                appIdentifier: Self.stringArg(args, "app"),
                windowID: try Self.uint32Arg(args, "windowId"),
                range: location.flatMap { location in length.map { AXTextRange(location: location, length: $0) } },
                text: Self.stringArg(args, "text"),
                session: Self.stringArg(args, "session"),
                agentCursor: try Self.boolArg(args, "agentCursor")
            )
            let result = try await engine.selectText(request)
            return try self.okOutcome(command: "select_text", result: ActionResultEnvelope(action: result))
        }
    }

    private func performActionTool() -> MCPTool {
        MCPTool(
            name: "perform_action",
            description: "Perform an accessibility action that the element lists in its actions, such as AXPress, AXShowMenu, AXIncrement, or AXScrollToVisible. Runs through accessibility only (tier ax), so it never activates the app or moves the user's cursor. A name the element does not list fails with element_not_actionable, which lists the ones it does.",
            inputSchema: objectSchema([
                "name": stringProp("Action to perform, from the element's actions. The AX prefix is optional."),
                "element": stringProp(Self.elementHelp),
                "elementId": stringProp(Self.elementIDHelp),
                "role": stringProp(Self.roleHelp),
            ], required: ["name"])
        ) { [engine] args in
            let request = PerformActionRequest(
                element: Self.stringArg(args, "element"),
                elementID: Self.stringArg(args, "elementId"),
                role: Self.stringArg(args, "role"),
                appIdentifier: Self.stringArg(args, "app"),
                windowID: try Self.uint32Arg(args, "windowId"),
                name: try Self.requireString(args, "name"),
                session: Self.stringArg(args, "session"),
                agentCursor: try Self.boolArg(args, "agentCursor")
            )
            let result = try await engine.performAction(request)
            return try self.okOutcome(command: "perform_action", result: ActionResultEnvelope(action: result))
        }
    }

    private func listAppsTool() -> MCPTool {
        MCPTool(
            name: "list_apps",
            description: "List running apps (name, bundle ID, pid, frontmost, on-screen window count) and installed apps (name, bundle ID, path, running) from /Applications, /System/Applications, and ~/Applications.",
            inputSchema: objectSchema([
                "includeInstalled": boolProp("Also list installed apps (default true). The scan is cached for a minute."),
                "filter": stringProp("Only list apps whose name or bundle ID contains this text, ignoring case."),
            ])
        ) { [engine] args in
            let request = AppsRequest(
                includeInstalled: try Self.boolArg(args, "includeInstalled") ?? true,
                filter: Self.stringArg(args, "filter")
            )
            return try self.okOutcome(command: "list_apps", result: engine.apps(request))
        }
    }

    private func launchAppTool() -> MCPTool {
        MCPTool(
            name: "launch_app",
            description: "Launch an app without activating it, and wait until it is running. If the app takes focus while it starts, the focus guard puts the previous app back, and the focus receipt reports what happened. An app that is already running is reported, not launched again.",
            inputSchema: objectSchema([
                "app": stringProp("App to launch: name, bundle ID, or path to an .app bundle."),
                "timeoutMs": numberProp("How long to wait for the app to finish launching, 1 to 120000 ms (default 10000)."),
                "session": stringProp("Agent session whose focus guard covers the launch. Default: $SCREENCOMMANDER_SESSION, else this server's serve-<pid>."),
            ], required: ["app"])
        ) { [engine] args in
            let request = LaunchRequest(
                appIdentifier: try Self.requireString(args, "app"),
                timeoutMS: try Self.intArg(args, "timeoutMs") ?? 10_000,
                session: Self.stringArg(args, "session")
            )
            let result = try await engine.launch(request)
            return try self.okOutcome(command: "launch_app", result: result)
        }
    }

    private func windowsTool() -> MCPTool {
        MCPTool(
            name: "windows",
            description: "List on-screen windows with their IDs, apps, pids, titles, bounds in points, and layers. Window IDs work as windowId on input tools and app_state, and as window on screenshot.",
            inputSchema: objectSchema([
                "app": stringProp("Only list windows of this app: name or pid."),
            ])
        ) { [engine] args in
            let result = try await engine.windows(WindowsRequest(appIdentifier: Self.stringArg(args, "app")))
            return try self.okOutcome(command: "windows", result: result)
        }
    }

    private func focusTool() -> MCPTool {
        MCPTool(
            name: "focus",
            description: "Bring an app to the front. This takes focus from the user, and input tools do not need it. Reports the previously frontmost app.",
            inputSchema: objectSchema([
                "app": stringProp("App to activate: name or pid."),
            ], required: ["app"])
        ) { [engine] args in
            let result = try await engine.focus(FocusRequest(appIdentifier: try Self.requireString(args, "app")))
            return try self.okOutcome(command: "focus", result: result)
        }
    }

    private func observeWaitTool() -> MCPTool {
        MCPTool(
            name: "observe_wait",
            description: "Watch an app's UI change events for up to timeoutMs, or until an element matches until. Returns the outcome and the events seen (the newest 500). An unmet until is an observe_timeout error that still carries the events.",
            inputSchema: objectSchema([
                "app": stringProp("Target app: name or pid."),
                "events": stringProp("Event kinds, comma-separated: value, focus, window, destroy, app (default all)."),
                "timeoutMs": numberProp("How long to watch, 1 to 600000 milliseconds."),
                "until": stringProp("Stop when an element matches this predicate, such as 'role=AXButton title~=Save'. Keys: role, title, value, id. = is exact, ~= is a case-insensitive substring. id matches only elements present at the start."),
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
            if case .timedOutUnmet = outcome {
                var failure = self.errorOutcome(command: "observe_wait", error: .observeTimeout("'until' predicate was not matched within \(timeout) ms."))
                if var envelope = failure.envelope.objectValue {
                    envelope["result"] = try JSONValue(encoding: result)
                    failure.envelope = .object(envelope)
                }
                return failure
            }
            return try self.okOutcome(command: "observe_wait", result: result)
        }
    }

    private func doctorTool() -> MCPTool {
        MCPTool(
            name: "doctor",
            description: "Check permissions (Screen Recording, Accessibility), displays, the private symbols background delivery needs, and the presence process. With app, also report that app's background delivery profile: support level, toolkit, and tier order. Sends no input.",
            inputSchema: objectSchema([
                "app": stringProp("App to profile: a running app (name or pid) or an installed one (name, bundle ID, or path)."),
            ])
        ) { [doctor, engine] args in
            var report = try doctor.collect()
            if let app = Self.stringArg(args, "app") {
                report.appProfile = try await engine.appProfile(identifier: app)
            }
            return try self.okOutcome(command: "doctor", result: report)
        }
    }

    private func cleanupTool() -> MCPTool {
        MCPTool(
            name: "cleanup",
            description: "Delete managed captures (.png, .jpeg, .jpg, .json in the captures directory) older than the given age. Keeps last-screenshot.json.",
            inputSchema: objectSchema([
                "olderThanHours": numberProp("Delete captures older than this many hours (default 24)."),
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

    private static func boolArg(_ args: JSONValue, _ key: String) throws -> Bool? {
        guard let value = args[key], value != .null else { return nil }
        guard let bool = value.boolValue else {
            throw ScreenCommanderError.invalidArguments("'\(key)' must be a boolean.")
        }
        return bool
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

    /// `via` accepts `pid` as the pre-1.0 name of `window`.
    private static func viaArg(_ args: JSONValue) throws -> InputDeliveryMethod? {
        guard let raw = stringArg(args, "via") else { return nil }
        guard let value = InputDeliveryMethod(parsing: raw) else {
            throw ScreenCommanderError.invalidArguments("Invalid value '\(raw)' for 'via'.")
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

    private func objectSchema(_ properties: [String: JSONValue], required: [String] = [], description: String? = nil) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map(JSONValue.string))
        }
        if let description {
            schema["description"] = .string(description)
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
    private var start = 0

    init(cap: Int) {
        self.cap = max(1, cap)
    }

    func append(_ event: ObservedEvent) {
        lock.lock()
        defer { lock.unlock() }
        if events.count < cap {
            events.append(event)
        } else {
            events[start] = event
            start = (start + 1) % cap
            dropped += 1
        }
    }

    func snapshot() -> (events: [ObservedEvent], dropped: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (Array(events[start...]) + Array(events[..<start]), dropped)
    }
}
