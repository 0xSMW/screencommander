import Foundation

/// Newline-delimited JSON-RPC 2.0, the framing MCP uses over stdio (one message per
/// line — not LSP-style Content-Length headers).
enum JSONRPCErrorCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}

struct JSONRPCRequest {
    var id: JSONValue?
    var method: String
    var params: JSONValue?
    /// A request without an `id` member is a notification and gets no response.
    /// (`"id": null` is preserved as a request with a null id.)
    var isNotification: Bool
}

struct JSONRPCErrorObject: Encodable, Equatable {
    var code: Int
    var message: String
}

struct JSONRPCResponse: Encodable {
    var jsonrpc = "2.0"
    var id: JSONValue
    var result: JSONValue?
    var error: JSONRPCErrorObject?

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case result
        case error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        // Exactly one of result/error, per JSON-RPC 2.0.
        if let error {
            try container.encode(error, forKey: .error)
        } else {
            try container.encode(result ?? .null, forKey: .result)
        }
    }

    static func success(id: JSONValue, result: JSONValue) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result, error: nil)
    }

    static func failure(id: JSONValue, code: Int, message: String) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: nil, error: JSONRPCErrorObject(code: code, message: message))
    }
}

enum JSONRPCCodec {
    /// Decodes one line. Returns nil for unparseable JSON or a structurally invalid
    /// request — the caller responds with parseError/invalidRequest (id null).
    static func decodeRequest(_ line: String) -> JSONRPCRequest? {
        guard let data = line.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue else {
            return nil
        }
        guard let method = object["method"]?.stringValue else {
            return nil
        }
        let hasID = object.keys.contains("id")
        return JSONRPCRequest(
            id: object["id"],
            method: method,
            params: object["params"],
            isNotification: !hasID
        )
    }

    /// One compact response line (no trailing newline).
    static func encode(_ response: JSONRPCResponse) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(response)
        guard let line = String(data: data, encoding: .utf8) else {
            throw ScreenCommanderError.metadataFailure("Could not encode JSON-RPC response.")
        }
        return line
    }
}
