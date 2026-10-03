import ArgumentParser
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
        XCTAssertEqual(ScreenCommanderError.backgroundDeliveryUnavailable("x").stableCode, "background_delivery_unavailable")
        XCTAssertEqual(ScreenCommanderError.backgroundDeliveryUnavailable("x").exitCode, 51)
        XCTAssertEqual(ScreenCommanderError.targetBusy("x").stableCode, "target_busy")
        XCTAssertEqual(ScreenCommanderError.targetBusy("x").exitCode, 52)
        XCTAssertEqual(ScreenCommanderError.abortedByUser("x").stableCode, "aborted_by_user")
        XCTAssertEqual(ScreenCommanderError.abortedByUser("x").exitCode, 53)
        XCTAssertEqual(ScreenCommanderError.userInterrupted("x").stableCode, "user_interrupted")
        XCTAssertEqual(ScreenCommanderError.userInterrupted("x").exitCode, 54)
        XCTAssertEqual(ScreenCommanderError.invalidArguments("x").stableCode, "invalid_arguments")
        XCTAssertEqual(ScreenCommanderError.axTreeUnavailable("x").stableCode, "ax_tree_unavailable")
        XCTAssertEqual(ScreenCommanderError.axTreeUnavailable("x").exitCode, 71)
        XCTAssertEqual(ScreenCommanderError.elementNotFound("x").stableCode, "element_not_found")
        XCTAssertEqual(ScreenCommanderError.elementNotActionable("x").stableCode, "element_not_actionable")
        XCTAssertEqual(ScreenCommanderError.observeTimeout("x").stableCode, "observe_timeout")
        XCTAssertEqual(ScreenCommanderError.observeTimeout("x").exitCode, 73)
        XCTAssertEqual(ScreenCommanderError.elementAmbiguous("x").stableCode, "element_ambiguous")
        XCTAssertEqual(ScreenCommanderError.elementAmbiguous("x").exitCode, 82)
    }

    // MARK: - Parse errors

    private func parseError(_ arguments: [String]) -> Error? {
        do {
            _ = try RootCommand.parseAsRoot(arguments)
            return nil
        } catch {
            return error
        }
    }

    func testParseErrorsAreAJSONErrorEnvelopeWhenJSONIsRequested() throws {
        for arguments in [["click", "--bogus", "--json"], ["--output", "json", "click", "--bogus"], ["click", "--output=json", "--bogus"]] {
            let error = try XCTUnwrap(parseError(arguments), "\(arguments)")
            let envelope = try XCTUnwrap(OutputOptions.parseErrorEnvelope(for: error, arguments: arguments, environment: [:]), "\(arguments)")
            XCTAssertEqual(envelope.status, "error")
            XCTAssertEqual(envelope.command, "click")
            XCTAssertEqual(envelope.error.code, "invalid_arguments")
            XCTAssertEqual(envelope.exitCode, 60)
            XCTAssertTrue(envelope.error.message.contains("--bogus"), envelope.error.message)
        }

        let missing = ["key", "--json"]
        let missingError = try XCTUnwrap(parseError(missing))
        XCTAssertEqual(OutputOptions.parseErrorEnvelope(for: missingError, arguments: missing, environment: [:])?.command, "key")

        let fromEnvironment = ["key", "--bogus"]
        let environmentError = try XCTUnwrap(parseError(fromEnvironment))
        XCTAssertNotNil(OutputOptions.parseErrorEnvelope(for: environmentError, arguments: fromEnvironment, environment: ["SCREENCOMMANDER_OUTPUT": "json"]))
        XCTAssertNil(OutputOptions.parseErrorEnvelope(for: environmentError, arguments: fromEnvironment, environment: [:]), "text stays text")

        XCTAssertNil(
            OutputOptions.parseErrorEnvelope(for: CleanExit.helpRequest(), arguments: ["click", "--help", "--json"], environment: [:]),
            "help prints as text"
        )
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

    func testExplicitHumanOutputOverridesJSONEnvironment() throws {
        OutputOptions.preScanned = (output: "human", compact: false)
        OutputOptions.preScannedOutputIsExplicit = true
        defer {
            OutputOptions.preScanned = (nil, false)
            OutputOptions.preScannedOutputIsExplicit = false
        }

        let resolved = try OutputOptions.effective(jsonFlag: false)

        XCTAssertEqual(resolved.format, .human)
    }

    func testInvalidOutputModeThrowsInsteadOfFallingBack() {
        OutputOptions.preScanned = (output: "jsno", compact: false)
        OutputOptions.preScannedOutputIsExplicit = true
        defer {
            OutputOptions.preScanned = (nil, false)
            OutputOptions.preScannedOutputIsExplicit = false
        }

        XCTAssertThrowsError(try OutputOptions.effective(jsonFlag: false)) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "invalid_arguments")
        }
    }

    func testInvalidExplicitOutputModeThrowsEvenWhenJsonFlagIsSet() {
        OutputOptions.preScanned = (output: "jsno", compact: false)
        OutputOptions.preScannedOutputIsExplicit = true
        defer {
            OutputOptions.preScanned = (nil, false)
            OutputOptions.preScannedOutputIsExplicit = false
        }

        XCTAssertThrowsError(try OutputOptions.effective(jsonFlag: true)) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "invalid_arguments")
        }
    }

    func testJsonFlagOverridesInvalidEnvironmentOutput() throws {
        OutputOptions.preScanned = (output: "jsno", compact: false)
        OutputOptions.preScannedOutputIsExplicit = false
        defer { OutputOptions.preScanned = (nil, false) }

        let resolved = try OutputOptions.effective(jsonFlag: true)

        XCTAssertEqual(resolved.format, .json)
    }
}
