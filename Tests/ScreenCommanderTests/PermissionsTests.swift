import XCTest
@testable import ScreenCommander

final class PermissionsTests: XCTestCase {
    func testAccessibilityPromptIsAttemptedOnlyOnceWhileDenied() {
        let trusted = false
        var promptCount = 0
        let permissions = Permissions(
            accessibilityTrusted: { trusted },
            requestAccessibilityTrust: {
                promptCount += 1
                return false
            }
        )

        XCTAssertThrowsError(try permissions.ensureAccessibilityAccess(prompt: true))
        XCTAssertThrowsError(try permissions.ensureAccessibilityAccess(prompt: true))
        XCTAssertEqual(promptCount, 1)
    }

    func testAccessibilityLaterGrantIsObservedWithoutRePrompting() throws {
        var trusted = false
        var promptCount = 0
        let permissions = Permissions(
            accessibilityTrusted: { trusted },
            requestAccessibilityTrust: {
                promptCount += 1
                return false
            }
        )

        XCTAssertThrowsError(try permissions.ensureAccessibilityAccess(prompt: true))
        trusted = true

        try permissions.ensureAccessibilityAccess(prompt: true)
        XCTAssertEqual(promptCount, 1)
    }

    func testAccessibilityNonPromptingCheckNeverRequestsTrust() {
        var promptCount = 0
        let permissions = Permissions(
            accessibilityTrusted: { false },
            requestAccessibilityTrust: {
                promptCount += 1
                return false
            }
        )

        XCTAssertThrowsError(try permissions.ensureAccessibilityAccess(prompt: false))
        XCTAssertEqual(promptCount, 0)
    }

    func testScreenRecordingPromptIsAttemptedOnlyOnceWhileDenied() {
        var promptCount = 0
        let permissions = Permissions(
            preflightScreenRecording: { false },
            requestScreenRecording: {
                promptCount += 1
                return false
            }
        )

        XCTAssertThrowsError(try permissions.ensureScreenRecordingAccess(prompt: true))
        XCTAssertThrowsError(try permissions.ensureScreenRecordingAccess(prompt: true))
        XCTAssertEqual(promptCount, 1)
    }

    func testScreenRecordingLaterGrantIsObservedWithoutRePrompting() throws {
        var granted = false
        var promptCount = 0
        let permissions = Permissions(
            preflightScreenRecording: { granted },
            requestScreenRecording: {
                promptCount += 1
                return false
            }
        )

        XCTAssertThrowsError(try permissions.ensureScreenRecordingAccess(prompt: true))
        granted = true

        try permissions.ensureScreenRecordingAccess(prompt: true)
        XCTAssertEqual(promptCount, 1)
    }

    func testScreenRecordingNonPromptingCheckNeverRequestsAccess() {
        var promptCount = 0
        let permissions = Permissions(
            preflightScreenRecording: { false },
            requestScreenRecording: {
                promptCount += 1
                return false
            }
        )

        XCTAssertThrowsError(try permissions.ensureScreenRecordingAccess(prompt: false))
        XCTAssertEqual(promptCount, 0)
    }
}
