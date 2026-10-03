import Foundation
import XCTest
@testable import ScreenCommanderPresence

final class FocusGuardRenewalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)

    func testRenewalPreservesHistoryAndRestoreLimit() {
        var state = PresenceState()
        _ = state.beginGuard(targetPID: 90, leaseMs: 3000, frontmostPID: 80, now: now)
        for offset in 1...3 {
            XCTAssertEqual(state.focusDecision(activatedPID: 90, now: now.addingTimeInterval(Double(offset) / 10), secondsSinceHIDInput: nil), .restore(80))
        }
        let original = state.guards[90]!
        _ = state.beginGuard(targetPID: 90, leaseMs: 5000, frontmostPID: 90, now: now.addingTimeInterval(1), renew: true)
        let renewed = state.guards[90]!
        XCTAssertEqual(renewed.previousFrontmostPID, 80)
        XCTAssertEqual(renewed.beganAt, original.beganAt)
        XCTAssertEqual(renewed.restoreCount, 3)
        XCTAssertEqual(renewed.lastRestoreAt, original.lastRestoreAt)
        XCTAssertEqual(renewed.expiresAt, now.addingTimeInterval(6))
        _ = state.beginGuard(targetPID: 90, leaseMs: 1000, frontmostPID: 70, now: now.addingTimeInterval(1), renew: true)
        XCTAssertEqual(state.guards[90]?.expiresAt, renewed.expiresAt)
        XCTAssertEqual(state.focusDecision(activatedPID: 90, now: now.addingTimeInterval(2), secondsSinceHIDInput: nil), .ignore(.restoreLimitReached))
    }

    func testRenewalDoesNotReviveGuardEndedByUserActivation() {
        var state = PresenceState()
        _ = state.beginGuard(targetPID: 90, leaseMs: 3000, frontmostPID: 80, now: now)
        XCTAssertEqual(state.focusDecision(activatedPID: 90, now: now, secondsSinceHIDInput: 0.1), .ignore(.userCaused))
        _ = state.beginGuard(targetPID: 90, leaseMs: 5000, frontmostPID: 80, now: now, renew: true)
        XCTAssertNil(state.guards[90])
    }

    func testOptionalWireFieldsDecodeOlderRequest() throws {
        let data = Data(#"{"pid":90,"leaseMs":3000,"session":"a"}"#.utf8)
        let params = try JSONDecoder().decode(GuardBeginParams.self, from: data)
        XCTAssertNil(params.renew)
        XCTAssertNil(params.previousFrontmostPID)
    }

    func testLaunchRepairUsesOriginalAppAndRunsOutsideLock() {
        let core = PresenceCore(driver: HeadlessCursorDriver(), environment: PresenceEnvironment(now: { self.now }, frontmostPID: { 90 }))
        var restored: pid_t?
        core.onRestoreFocus = { previous, target in
            restored = previous
            XCTAssertEqual(target, 90)
            XCTAssertEqual(core.snapshot.guards[90]?.restoreCount, 1)
        }
        core.handle(PresenceRequestEnvelope(id: 1, request: .guardBegin(GuardBeginParams(pid: 90, leaseMs: 3000, previousFrontmostPID: 80))), connection: 1) { _ in }
        XCTAssertEqual(restored, 80)
    }

    func testLaunchRepairYieldsToRecentUserInput() {
        let core = PresenceCore(driver: HeadlessCursorDriver(), environment: PresenceEnvironment(now: { self.now }, frontmostPID: { 90 }, secondsSinceHIDInput: { 0.1 }))
        core.onRestoreFocus = { _, _ in XCTFail("User activation must remain frontmost") }
        core.handle(PresenceRequestEnvelope(id: 1, request: .guardBegin(GuardBeginParams(pid: 90, leaseMs: 3000, previousFrontmostPID: 80))), connection: 1) { _ in }
        XCTAssertNil(core.snapshot.guards[90])
    }

    func testLaunchFallbackDoesNotOverrideCurrentFrontmostApp() {
        var state = PresenceState()
        _ = state.beginGuard(targetPID: 90, leaseMs: 3000, frontmostPID: 70, now: now, previousFrontmostPID: 80)
        XCTAssertEqual(state.guards[90]?.previousFrontmostPID, 70)
    }

    func testLaunchRepairYieldsToRecentSpaceChange() {
        let core = PresenceCore(driver: HeadlessCursorDriver(), environment: PresenceEnvironment(now: { self.now }, frontmostPID: { 90 }))
        core.spaceChanged()
        core.onRestoreFocus = { _, _ in XCTFail("Space changes must suppress launch restoration") }
        core.handle(PresenceRequestEnvelope(id: 1, request: .guardBegin(GuardBeginParams(pid: 90, leaseMs: 3000, previousFrontmostPID: 80))), connection: 1) { _ in }
        XCTAssertNil(core.snapshot.guards[90])
    }
}
