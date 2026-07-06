import Foundation

/// Stdio MCP server core: one JSON-RPC message per line in, one per line out.
/// `handle(line:)` is the whole protocol surface, so tests drive it directly with
/// strings — no pipes or process plumbing required.
final class MCPServer {
    static let protocolVersion = "2025-06-18"
    static let serverName = "screencommander"
    static let serverVersion = "0.4.0"

    private let registry: MCPToolRegistry
    private let stateLock = NSLock()
    private var initialized = false

    init(registry: MCPToolRegistry) {
        self.registry = registry
    }

    /// Processes one incoming line. Returns the response line, or nil when no
    /// response is due (notifications, blank lines).
    func handle(line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return nil
        }

        guard let request = JSONRPCCodec.decodeRequest(trimmed) else {
            return encodeOrNil(.failure(id: .null, code: JSONRPCErrorCode.parseError, message: "Could not parse JSON-RPC request."))
        }
        return await handle(request: request)
    }

    /// Processes one decoded JSON-RPC request. Serve-mode dispatchers use this to
    /// parse once at the transport boundary, then schedule work without reparsing.
    func handle(request: JSONRPCRequest) async -> String? {
        if request.isNotification {
            // notifications/initialized, notifications/cancelled, etc. — nothing to say.
            return nil
        }

        let id = request.id ?? .null
        let response = await respond(to: request, id: id)
        return encodeOrNil(response)
    }

    private func respond(to request: JSONRPCRequest, id: JSONValue) async -> JSONRPCResponse {
        switch request.method {
        case "initialize":
            setInitialized(true)
            return .success(id: id, result: initializeResult())

        case "ping":
            return .success(id: id, result: .object([:]))

        case "tools/list":
            guard isInitialized else {
                return .failure(id: id, code: JSONRPCErrorCode.invalidRequest, message: "Server must be initialized before tools/list.")
            }
            return .success(id: id, result: registry.listToolsResult())

        case "tools/call":
            guard isInitialized else {
                return .failure(id: id, code: JSONRPCErrorCode.invalidRequest, message: "Server must be initialized before tools/call.")
            }
            guard let name = request.params?["name"]?.stringValue else {
                return .failure(id: id, code: JSONRPCErrorCode.invalidParams, message: "tools/call requires a 'name' parameter.")
            }
            let arguments = request.params?["arguments"] ?? .object([:])
            guard let outcome = await registry.call(name: name, arguments: arguments) else {
                return .failure(id: id, code: JSONRPCErrorCode.invalidParams, message: "Unknown tool '\(name)'.")
            }
            return .success(id: id, result: callResult(outcome))

        default:
            return .failure(id: id, code: JSONRPCErrorCode.methodNotFound, message: "Method '\(request.method)' is not supported.")
        }
    }

    private var isInitialized: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return initialized
    }

    private func setInitialized(_ value: Bool) {
        stateLock.lock()
        initialized = value
        stateLock.unlock()
    }

    private func initializeResult() -> JSONValue {
        // We implement exactly one protocol revision. Per the MCP lifecycle spec, a
        // server that doesn't support the requested version responds with one it
        // DOES support (never a blind echo — that would falsely negotiate unknown
        // revisions); the client then decides whether to proceed or disconnect.
        return .object([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object([
                "tools": .object(["listChanged": .bool(false)])
            ]),
            "serverInfo": .object([
                "name": .string(Self.serverName),
                "version": .string(Self.serverVersion),
            ]),
            "instructions": .string(
                "Screen capture and input synthesis for macOS. Take a screenshot (or read elements) "
                    + "before coordinate actions — pixel coordinates map through the capture's metadata. "
                    + "Element-targeted clicks/typing avoid moving the user's cursor."
            ),
        ])
    }

    private func callResult(_ outcome: MCPToolOutcome) -> JSONValue {
        var content = outcome.extraContent
        let text = (try? outcome.envelope.compactLine()) ?? "{}"
        content.append(.object([
            "type": .string("text"),
            "text": .string(text),
        ]))
        return .object([
            "content": .array(content),
            "structuredContent": outcome.envelope,
            "isError": .bool(outcome.isError),
        ])
    }

    private func encodeOrNil(_ response: JSONRPCResponse) -> String? {
        // An unencodable response has no in-band representation left; stderr is the
        // only honest channel.
        do {
            return try JSONRPCCodec.encode(response)
        } catch {
            writeError("mcp: could not encode response: \(error)")
            return nil
        }
    }
}
