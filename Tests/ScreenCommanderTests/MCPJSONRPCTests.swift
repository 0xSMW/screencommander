import Foundation
import XCTest
@testable import ScreenCommander

final class MCPJSONRPCTests: XCTestCase {
    // MARK: - JSONValue

    func testJSONValueRoundTripsNestedStructures() throws {
        let raw = #"{"a":[1,2.5,true,null,"x"],"b":{"c":"d"},"e":-3}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))

        XCTAssertEqual(value["a"]?.arrayValue?.count, 5)
        XCTAssertEqual(value["a"]?.arrayValue?[0].intValue, 1)
        XCTAssertEqual(value["a"]?.arrayValue?[1].numberValue, 2.5)
        XCTAssertEqual(value["a"]?.arrayValue?[2].boolValue, true)
        XCTAssertEqual(value["a"]?.arrayValue?[3], .null)
        XCTAssertEqual(value["b"]?["c"]?.stringValue, "d")
        XCTAssertEqual(value["e"]?.intValue, -3)

        let reencoded = try JSONDecoder().decode(JSONValue.self, from: Data(try value.compactLine().utf8))
        XCTAssertEqual(reencoded, value)
    }

    func testJSONValueEncodesWholeNumbersWithoutFraction() throws {
        let line = try JSONValue.object(["id": .number(7)]).compactLine()
        XCTAssertEqual(line, #"{"id":7}"#)
    }

    func testJSONValueEncodingFromEncodable() throws {
        struct Sample: Encodable {
            var name = "x"
            var count = 2
        }
        let value = try JSONValue(encoding: Sample())
        XCTAssertEqual(value["name"]?.stringValue, "x")
        XCTAssertEqual(value["count"]?.intValue, 2)
    }

    // MARK: - Request decoding

    func testDecodesRequestWithNumberID() throws {
        let request = try XCTUnwrap(JSONRPCCodec.decodeRequest(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#))
        XCTAssertEqual(request.method, "ping")
        XCTAssertEqual(request.id, .number(1))
        XCTAssertFalse(request.isNotification)
    }

    func testDecodesRequestWithStringIDAndParams() throws {
        let request = try XCTUnwrap(
            JSONRPCCodec.decodeRequest(#"{"jsonrpc":"2.0","id":"a-1","method":"tools/call","params":{"name":"doctor"}}"#)
        )
        XCTAssertEqual(request.id, .string("a-1"))
        XCTAssertEqual(request.params?["name"]?.stringValue, "doctor")
    }

    func testRequestWithoutIDIsNotification() throws {
        let request = try XCTUnwrap(
            JSONRPCCodec.decodeRequest(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        )
        XCTAssertTrue(request.isNotification)
    }

    func testRequestWithNullIDIsNotANotification() throws {
        let request = try XCTUnwrap(JSONRPCCodec.decodeRequest(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#))
        XCTAssertFalse(request.isNotification)
        XCTAssertEqual(request.id, .null)
    }

    func testRejectsUnparseableAndStructurallyInvalidLines() {
        XCTAssertNil(JSONRPCCodec.decodeRequest("not json"))
        XCTAssertNil(JSONRPCCodec.decodeRequest(#"[1,2,3]"#))
        XCTAssertNil(JSONRPCCodec.decodeRequest(#"{"jsonrpc":"2.0","id":1}"#))
    }

    // MARK: - Response encoding

    func testEncodesSuccessResponse() throws {
        let line = try JSONRPCCodec.encode(.success(id: .number(3), result: .object(["ok": .bool(true)])))
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        XCTAssertEqual(value["jsonrpc"]?.stringValue, "2.0")
        XCTAssertEqual(value["id"]?.intValue, 3)
        XCTAssertEqual(value["result"]?["ok"]?.boolValue, true)
        XCTAssertNil(value["error"])
        XCTAssertFalse(line.contains("\n"))
    }

    func testEncodesErrorResponseWithoutResult() throws {
        let line = try JSONRPCCodec.encode(.failure(id: .null, code: JSONRPCErrorCode.methodNotFound, message: "nope"))
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        XCTAssertEqual(value["error"]?["code"]?.intValue, -32601)
        XCTAssertEqual(value["error"]?["message"]?.stringValue, "nope")
        XCTAssertNil(value["result"])
        XCTAssertEqual(value["id"], .null)
    }
}
