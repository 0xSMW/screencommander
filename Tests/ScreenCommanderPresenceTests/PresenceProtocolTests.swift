import Foundation
import XCTest
@testable import ScreenCommanderPresence

final class PresenceProtocolTests: XCTestCase {
    func testEveryRequestRoundTrips() throws {
        let requests: [PresenceRequest] = [
            .hello(HelloParams(pid: 42, client: "test")),
            .sessionAcquire(SessionAcquireParams(session: "a", pid: 99, holdMs: 5000)),
            .sessionRelease(SessionReleaseParams(session: "a", pid: 99)),
            .sessionRelease(SessionReleaseParams(session: "a")),
            .cursorMoveTo(CursorMoveParams(session: "a", point: PresencePoint(x: 10.5, y: -20), windowID: 1234, timing: .finished)),
            .cursorPress(CursorPressParams(session: "a", count: 2)),
            .cursorSetState(CursorSetStateParams(session: "a", state: .loading)),
            .cursorHide(CursorHideParams(session: "a")),
            .guardBegin(GuardBeginParams(pid: 99, leaseMs: 2000, session: "a")),
            .guardEnd(GuardEndParams(pid: 99)),
            .status,
            .resume,
            .shutdown
        ]
        XCTAssertEqual(Set(requests.map(\.method)), Set(PresenceMethod.allCases))

        for (index, request) in requests.enumerated() {
            let envelope = PresenceRequestEnvelope(id: UInt64(index + 1), request: request)
            let line = try envelope.encodeLine()
            XCTAssertEqual(line.last, 0x0A)
            XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1, "One request per line")
            let decoded = try JSONDecoder().decode(PresenceRequestEnvelope.self, from: line.dropLast())
            XCTAssertEqual(decoded, envelope)
        }
    }

    func testWireShapeUsesDottedMethodNames() throws {
        let envelope = PresenceRequestEnvelope(
            id: 7,
            request: .cursorMoveTo(CursorMoveParams(session: "s", point: PresencePoint(x: 1, y: 2)))
        )
        let object = try JSONSerialization.jsonObject(with: envelope.encodeLine()) as? [String: Any]
        XCTAssertEqual(object?["method"] as? String, "cursor.moveTo")
        XCTAssertEqual(object?["id"] as? Int, 7)
        let params = object?["params"] as? [String: Any]
        XCTAssertEqual(params?["timing"] as? String, "closeEnough")
    }

    func testOptionalParamsDefault() throws {
        let move = #"{"id":1,"method":"cursor.moveTo","params":{"session":"s","point":{"x":3,"y":4}}}"#
        let decodedMove = try JSONDecoder().decode(PresenceRequestEnvelope.self, from: Data(move.utf8))
        XCTAssertEqual(decodedMove.request, .cursorMoveTo(CursorMoveParams(session: "s", point: PresencePoint(x: 3, y: 4))))

        let press = #"{"id":2,"method":"cursor.press","params":{"session":"s"}}"#
        let decodedPress = try JSONDecoder().decode(PresenceRequestEnvelope.self, from: Data(press.utf8))
        XCTAssertEqual(decodedPress.request, .cursorPress(CursorPressParams(session: "s", count: 1)))

        let status = #"{"id":3,"method":"status"}"#
        XCTAssertEqual(try JSONDecoder().decode(PresenceRequestEnvelope.self, from: Data(status.utf8)).request, .status)
    }

    func testUnknownMethodFailsToDecode() {
        let line = #"{"id":1,"method":"cursor.teleport","params":{}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(PresenceRequestEnvelope.self, from: Data(line.utf8)))
    }

    func testResponsesRoundTrip() throws {
        let status = PresenceStatus(
            protocolVersion: PresenceProtocol.version,
            serverPID: 10,
            aborted: true,
            tapAvailable: false,
            overlayWindowIDs: [301, 302],
            sessions: [SessionStatus(id: "a", pids: [99], userActive: true, lastUserInputMsAgo: 120, state: .paused, colorIndex: 1)],
            guardedPIDs: [99],
            guardRestores: [GuardRestoreStatus(pid: 99, restoreCount: 1, lastRestoreMsAgo: 40)]
        )
        let cases: [(PresenceMethod, PresenceResponse)] = [
            (.hello, .success(id: 1, .hello(HelloResult(protocolVersion: 1, serverPID: 10, tapAvailable: true)))),
            (.sessionAcquire, .success(id: 2, .lease(LeaseResult(session: "a", pid: 99, colorIndex: 0)))),
            (.sessionAcquire, .failure(id: 3, .targetBusy, "busy")),
            (.cursorMoveTo, .success(id: 4, .cursorMove(CursorMoveResult(
                session: "a", point: PresencePoint(x: 1, y: 2), arrived: true, visible: true, cursorWindowID: 301
            )))),
            (.cursorPress, .success(id: 5, .empty)),
            (.guardBegin, .success(id: 6, .guardLease(GuardResult(pid: 99, previousFrontmostPID: 55, leaseMs: 2000)))),
            (.status, .success(id: 7, .status(status))),
            (.resume, .success(id: 8, .empty)),
            (.cursorMoveTo, .failure(id: 9, .abortedByUser, "stopped"))
        ]
        for (method, response) in cases {
            let line = try response.encodeLine()
            XCTAssertEqual(PresenceResponse.peekID(in: line), response.id)
            XCTAssertEqual(try PresenceResponse.decode(line, method: method), response)
        }
    }

    /// A presence process from an older build sends no `guardRestores`. Clients
    /// must decode that as "unknown", not fail.
    func testStatusFromAnOlderServerDecodesWithoutGuardRestores() throws {
        let line = #"{"id":7,"ok":true,"result":{"protocolVersion":1,"serverPID":10,"aborted":false,"tapAvailable":true,"overlayWindowIDs":[],"sessions":[],"guardedPIDs":[99]}}"#
        guard case .success(.status(let status)) = try PresenceResponse.decode(Data(line.utf8), method: .status).outcome else {
            return XCTFail("Expected a status result")
        }
        XCTAssertEqual(status.guardedPIDs, [99])
        XCTAssertNil(status.guardRestores)
    }

    func testErrorCodesUseSnakeCase() throws {
        let line = try PresenceResponse.failure(id: 1, .targetBusy, "x").encodeLine()
        let text = String(decoding: line, as: UTF8.self)
        XCTAssertTrue(text.contains(#""code":"target_busy""#), text)
        XCTAssertTrue(text.contains(#""ok":false"#), text)
    }
}
