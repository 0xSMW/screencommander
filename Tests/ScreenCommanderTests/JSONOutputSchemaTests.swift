import Foundation
import XCTest
@testable import ScreenCommander

final class JSONOutputSchemaTests: XCTestCase {

    // MARK: - Stable error codes (spec Section 7)

    func testStableErrorCodes() {
        XCTAssertEqual(ScreenCommanderError.permissionDeniedScreenRecording.stableCode, "permission_denied_screen_recording")
        XCTAssertEqual(ScreenCommanderError.permissionDeniedAccessibility.stableCode, "permission_denied_accessibility")
        XCTAssertEqual(ScreenCommanderError.captureFailed("x").stableCode, "capture_failed")
        XCTAssertEqual(ScreenCommanderError.imageWriteFailed("x").stableCode, "image_write_failed")
        XCTAssertEqual(ScreenCommanderError.metadataFailure("x").stableCode, "metadata_failure")
        XCTAssertEqual(ScreenCommanderError.invalidCoordinate("x").stableCode, "invalid_coordinate")
        XCTAssertEqual(ScreenCommanderError.mappingFailed("x").stableCode, "mapping_failed")
        XCTAssertEqual(ScreenCommanderError.inputSynthesisFailed("x").stableCode, "input_synthesis_failed")
        XCTAssertEqual(ScreenCommanderError.invalidArguments("x").stableCode, "invalid_arguments")
    }

    // MARK: - Success envelope structure

    func testSuccessEnvelopeEncodesWithRequiredKeys() throws {
        let result = DoctorReport(
            permissions: DoctorPermissionStatus(screenRecordingGranted: true, accessibilityGranted: true),
            displays: []
        )
        let envelope = CommandEnvelope(status: "ok", command: "doctor", result: result, exitCode: 0)
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?["status"] as? String, "ok")
        XCTAssertEqual(decoded?["command"] as? String, "doctor")
        XCTAssertNotNil(decoded?["result"])
        XCTAssertEqual(decoded?["exitCode"] as? Int, 0)
    }

    // MARK: - Error envelope structure

    func testErrorEnvelopeEncodesWithRequiredKeys() throws {
        let err = ScreenCommanderError.invalidArguments("test message")
        let envelope = ErrorEnvelope(
            status: "error",
            command: "click",
            error: ErrorDetail(code: err.stableCode, message: err.description),
            exitCode: err.exitCode
        )
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?["status"] as? String, "error")
        XCTAssertEqual(decoded?["command"] as? String, "click")
        XCTAssertEqual(decoded?["exitCode"] as? Int32, 60)
        let errorObj = decoded?["error"] as? [String: Any]
        XCTAssertNotNil(errorObj)
        XCTAssertEqual(errorObj?["code"] as? String, "invalid_arguments")
        XCTAssertNotNil(errorObj?["message"] as? String)
    }
}
