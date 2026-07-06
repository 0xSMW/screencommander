import Foundation

/// Stdio MCP server core: one JSON-RPC message per line in, one per line out.
/// `handle(line:)` is the whole protocol surface, so tests drive it directly with
/// strings — no pipes or process plumbing required.
final class MCPServer {
    static let protocolVersion = "2025-06-18"
    static let serverName = "screencommander"
    static let serverVersion = "1.0.0"

    private let registry: MCPToolRegistry
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
            initialized = true
            return .success(id: id, result: initializeResult(params: request.params))

        case "ping":
            return .success(id: id, result: .object([:]))

        case "tools/list":
            do {
                return .success(id: id, result: try registry.listToolsResult())
            } catch {
                return .failure(id: id, code: JSONRPCErrorCode.internalError, message: "Could not list tools: \(error)")
            }

        case "tools/call":
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

    private func initializeResult(params: JSONValue?) -> JSONValue {
        // Echo the client's requested protocol version when it names one (we speak a
        // single revision; version negotiation is the client's problem to detect).
        let requested = params?["protocolVersion"]?.stringValue
        return .object([
            "protocolVersion": .string(requested ?? Self.protocolVersion),
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
