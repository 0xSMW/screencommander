import Foundation
import XCTest
@testable import ScreenCommanderPresence

final class PresenceStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let ownPID: pid_t = 500
    private let alive: (pid_t) -> Bool = { _ in true }

    // MARK: Leases

    func testSecondSessionOnLeasedPIDIsTargetBusy() {
        var state = PresenceState()
        state.openConnection(1, peerPID: 101)
        state.openConnection(2, peerPID: 102)

        XCTAssertNotNil(state.acquire(session: "a", targetPID: 900, holdMs: nil, connection: 1, now: t0).value)
        let busy = state.acquire(session: "b", targetPID: 900, holdMs: nil, connection: 2, now: t0)
        XCTAssertEqual(busy.error?.code, .targetBusy)

        // Different target is fine, and the same session may re-acquire.
        XCTAssertNotNil(state.acquire(session: "b", targetPID: 901, holdMs: nil, connection: 2, now: t0).value)
        XCTAssertNotNil(state.acquire(session: "a", targetPID: 900, holdMs: nil, connection: 1, now: t0).value)
        XCTAssertEqual(state.leasedPIDs(for: "a"), [900])
        XCTAssertEqual(state.leasedPIDs(for: "b"), [901])
    }

    func testReleaseFreesTheTarget() {
        var state = PresenceState()
        state.openConnection(1, peerPID: nil)
        state.openConnection(2, peerPID: nil)
        _ = state.acquire(session: "a", targetPID: 900, holdMs: nil, connection: 1, now: t0)
        state.release(session: "b", targetPID: 900, now: t0)
        XCTAssertEqual(state.acquire(session: "b", targetPID: 900, holdMs: nil, connection: 2, now: t0).error?.code, .targetBusy, "Only the holder can release")
        state.release(session: "a", targetPID: 900, now: t0)
        XCTAssertNotNil(state.acquire(session: "b", targetPID: 900, holdMs: nil, connection: 2, now: t0).value)
    }

    func testReleasingWithoutPIDEndsTheSession() {
        var state = PresenceState()
        state.openConnection(1, peerPID: nil)
        _ = state.acquire(session: "a", targetPID: 900, holdMs: nil, connection: 1, now: t0)
        _ = state.acquire(session: "a", targetPID: 901, holdMs: nil, connection: 1, now: t0)
        XCTAssertTrue(state.release(session: "a", targetPID: nil, now: t0))
        XCTAssertNil(state.sessions["a"])
        XCTAssertTrue(state.leases.isEmpty)
    }

    func testLeaseExpiresWhenClientVanishes() {
        var state = PresenceState()
        state.openConnection(1, peerPID: 101)
        _ = state.acquire(session: "a", targetPID: 900, holdMs: nil, connection: 1, now: t0)
        state.closeConnection(1, now: t0)
        XCTAssertNil(state.leases[900])

        state.openConnection(2, peerPID: 102)
        XCTAssertNotNil(state.acquire(session: "b", targetPID: 900, holdMs: nil, connection: 2, now: t0).value)
    }

    func testHeldLeaseOutlivesConnectionUntilHoldExpires() {
        var state = PresenceState()
        state.openConnection(1, peerPID: 101)
        _ = state.acquire(session: "a", targetPID: 900, holdMs: 3000, connection: 1, now: t0)
        state.closeConnection(1, now: t0)

        state.openConnection(2, peerPID: 102)
        XCTAssertEqual(state.acquire(session: "b", targetPID: 900, holdMs: nil, connection: 2, now: t0.addingTimeInterval(1)).error?.code, .targetBusy)

        // The same session can pick it back up from a new connection.
        state.openConnection(3, peerPID: 103)
        XCTAssertNotNil(state.acquire(session: "a", targetPID: 900, holdMs: 3000, connection: 3, now: t0.addingTimeInterval(1)).value)
        XCTAssertEqual(state.leases[900]?.owner, 3)
        state.closeConnection(3, now: t0.addingTimeInterval(1))

        _ = state.sweep(now: t0.addingTimeInterval(3.9), isProcessAlive: alive)
        XCTAssertNotNil(state.leases[900])
        _ = state.sweep(now: t0.addingTimeInterval(4.1), isProcessAlive: alive)
        XCTAssertNil(state.leases[900])
    }

    func testLeaseOnDeadTargetIsSwept() {
        var state = PresenceState()
        state.openConnection(1, peerPID: nil)
        _ = state.acquire(session: "a", targetPID: 900, holdMs: nil, connection: 1, now: t0)
        _ = state.sweep(now: t0, isProcessAlive: { $0 != 900 })
        XCTAssertNil(state.leases[900])
    }

    func testSessionWithoutLeaseEndsAfterItsLingerEvenWhileConnected() {
        var config = PresenceStateConfiguration()
        config.cursorLinger = 10
        var state = PresenceState(configuration: config)
        state.openConnection(1, peerPID: nil)
        state.touchSession("a", connection: 1, now: t0)
        XCTAssertEqual(state.sweep(now: t0.addingTimeInterval(9), isProcessAlive: alive), PresenceSweep())
        XCTAssertEqual(state.sweep(now: t0.addingTimeInterval(10), isProcessAlive: alive).ended, ["a"], "an open connection keeps nothing alive")
        XCTAssertTrue(state.isIdle, "a connected client does not keep the process from idling out")
    }

    // MARK: Idle lifetimes (finding: serve never released anything)

    func testLeaseOfAConnectedClientIsReleasedAfterItsIdlePeriod() {
        var state = PresenceState()
        state.openConnection(1, peerPID: 101)
        state.openConnection(2, peerPID: 102)
        XCTAssertNotNil(state.acquire(session: "serve-1", targetPID: 900, holdMs: 0, idleMs: 15_000, connection: 1, now: t0).value)

        XCTAssertEqual(state.acquire(session: "b", targetPID: 900, holdMs: 0, connection: 2, now: t0.addingTimeInterval(14)).error?.code, .targetBusy)
        _ = state.sweep(now: t0.addingTimeInterval(15), isProcessAlive: alive)
        XCTAssertNil(state.leases[900], "the lease went idle although its client is still connected")
        XCTAssertNotNil(state.acquire(session: "b", targetPID: 900, holdMs: 0, connection: 2, now: t0.addingTimeInterval(15)).value)
    }

    func testIdleLeaseCanBeTakenBeforeTheSweepRuns() {
        var state = PresenceState()
        state.openConnection(1, peerPID: 101)
        state.openConnection(2, peerPID: 102)
        _ = state.acquire(session: "a", targetPID: 900, holdMs: 0, idleMs: 2_000, connection: 1, now: t0)
        XCTAssertNotNil(state.acquire(session: "b", targetPID: 900, holdMs: 0, connection: 2, now: t0.addingTimeInterval(2)).value)
    }

    func testActingOnTheAppRenewsTheLease() {
        var state = PresenceState()
        state.openConnection(1, peerPID: 101)
        _ = state.acquire(session: "a", targetPID: 900, holdMs: 0, idleMs: 10_000, connection: 1, now: t0)
        _ = state.acquire(session: "a", targetPID: 900, holdMs: 0, idleMs: 10_000, connection: 1, now: t0.addingTimeInterval(8))
        state.noteActed(session: "a", targetPID: 900, now: t0.addingTimeInterval(16))
        _ = state.sweep(now: t0.addingTimeInterval(25), isProcessAlive: alive)
        XCTAssertNotNil(state.leases[900])
        _ = state.sweep(now: t0.addingTimeInterval(26), isProcessAlive: alive)
        XCTAssertNil(state.leases[900])
    }

    func testIdleLeasesAreTrackedPerApp() {
        var state = PresenceState()
        state.openConnection(1, peerPID: 101)
        _ = state.acquire(session: "a", targetPID: 900, holdMs: 0, idleMs: 10_000, connection: 1, now: t0)
        _ = state.acquire(session: "a", targetPID: 901, holdMs: 0, idleMs: 10_000, connection: 1, now: t0)
        for second in stride(from: 3.0, through: 12, by: 3) {
            _ = state.acquire(session: "a", targetPID: 901, holdMs: 0, idleMs: 10_000, connection: 1, now: t0.addingTimeInterval(second))
        }
        _ = state.sweep(now: t0.addingTimeInterval(12), isProcessAlive: alive)
        XCTAssertEqual(state.leasedPIDs(for: "a"), [901], "acting on one app does not keep the other")
    }

    func testCursorLingersThenHidesAndTheSessionEndsWithItsLastLease() {
        var state = PresenceState()
        state.openConnection(1, peerPID: 101)
        _ = state.acquire(session: "a", targetPID: 900, holdMs: 0, idleMs: 15_000, lingerMs: 5_000, connection: 1, now: t0)
        state.setCursorState(.loading, session: "a", connection: 1, now: t0.addingTimeInterval(1))

        XCTAssertEqual(state.sweep(now: t0.addingTimeInterval(5.9), isProcessAlive: alive), PresenceSweep())
        XCTAssertEqual(state.sweep(now: t0.addingTimeInterval(6), isProcessAlive: alive), PresenceSweep(hidden: ["a"]))
        XCTAssertEqual(state.sweep(now: t0.addingTimeInterval(7), isProcessAlive: alive), PresenceSweep(), "hidden once")
        XCTAssertNotNil(state.sessions["a"], "the session holds its lease")

        XCTAssertEqual(state.sweep(now: t0.addingTimeInterval(15), isProcessAlive: alive), PresenceSweep(ended: ["a"]))
        XCTAssertTrue(state.isIdle)
    }

    func testAGlideBringsAHiddenCursorBack() {
        var state = PresenceState()
        state.openConnection(1, peerPID: 101)
        _ = state.acquire(session: "a", targetPID: 900, holdMs: 0, idleMs: 15_000, lingerMs: 2_000, connection: 1, now: t0)
        XCTAssertEqual(state.sweep(now: t0.addingTimeInterval(2), isProcessAlive: alive).hidden, ["a"])
        _ = state.acquire(session: "a", targetPID: 900, holdMs: 0, idleMs: 15_000, lingerMs: 2_000, connection: 1, now: t0.addingTimeInterval(3))
        state.noteCursorShown(session: "a")
        XCTAssertEqual(state.sweep(now: t0.addingTimeInterval(5), isProcessAlive: alive).hidden, ["a"], "hidden again after the next linger")
    }

    func testClosingAServeConnectionReleasesItsLeasesAndSessionsAtOnce() {
        var state = PresenceState()
        state.openConnection(1, peerPID: 101)
        state.openConnection(2, peerPID: 102)
        _ = state.acquire(session: "serve-1", targetPID: 900, holdMs: 0, connection: 1, now: t0)
        _ = state.acquire(session: "serve-1", targetPID: 901, holdMs: 0, connection: 1, now: t0)

        XCTAssertEqual(state.closeConnection(1, now: t0.addingTimeInterval(1)), ["serve-1"])
        XCTAssertTrue(state.leases.isEmpty)
        XCTAssertNil(state.sessions["serve-1"])
        XCTAssertNotNil(state.acquire(session: "b", targetPID: 900, holdMs: 0, connection: 2, now: t0.addingTimeInterval(1)).value)
    }

    func testOneShotLeaseOutlivesItsProcessUntilItGoesIdle() {
        var state = PresenceState()
        state.openConnection(1, peerPID: 101)
        _ = state.acquire(session: "default", targetPID: 900, holdMs: 15_000, idleMs: 15_000, connection: 1, now: t0)
        XCTAssertEqual(state.closeConnection(1, now: t0.addingTimeInterval(0.5)), [], "the CLI exited but the session keeps its app")

        state.openConnection(2, peerPID: 102)
        XCTAssertEqual(state.acquire(session: "b", targetPID: 900, holdMs: 0, connection: 2, now: t0.addingTimeInterval(10)).error?.code, .targetBusy)
        _ = state.sweep(now: t0.addingTimeInterval(15), isProcessAlive: alive)
        XCTAssertNil(state.leases[900])
    }

    func testAbortKeepsTheProcessFromIdlingOutUntilResume() {
        var state = PresenceState()
        XCTAssertTrue(state.isIdle)
        XCTAssertEqual(state.recordUserInput(sourcePID: 0, targetPID: nil, isAbortChord: true, ownPID: ownPID, now: t0), .aborted)
        XCTAssertFalse(state.isIdle, "exiting would forget the abort")
        state.resume()
        XCTAssertTrue(state.isIdle)
    }

    func testSessionsGetDistinctColors() {
        var state = PresenceState()
        let a = state.touchSession("a", connection: nil, now: t0)
        let b = state.touchSession("b", connection: nil, now: t0)
        let c = state.touchSession("c", connection: nil, now: t0)
        XCTAssertEqual(Set([a.colorIndex, b.colorIndex, c.colorIndex]).count, 3)
        state.endSession("b")
        XCTAssertEqual(state.touchSession("d", connection: nil, now: t0).colorIndex, b.colorIndex, "Freed slot is reused")
    }

    // MARK: User activity

    func testUserInputInLeasedAppMarksSessionActiveForQuietPeriod() {
        var state = PresenceState()
        state.openConnection(1, peerPID: 101)
        _ = state.acquire(session: "a", targetPID: 900, holdMs: nil, connection: 1, now: t0)
        _ = state.acquire(session: "b", targetPID: 901, holdMs: nil, connection: 1, now: t0)

        let effect = state.recordUserInput(sourcePID: 0, targetPID: 900, isAbortChord: false, ownPID: ownPID, now: t0)
        XCTAssertEqual(effect, .recorded(sessions: ["a"]))
        XCTAssertTrue(state.isUserActive(session: "a", now: t0.addingTimeInterval(0.5)))
        XCTAssertFalse(state.isUserActive(session: "b", now: t0.addingTimeInterval(0.5)))
        XCTAssertFalse(state.isUserActive(session: "a", now: t0.addingTimeInterval(1.0)))

        let statuses = state.sessionStatuses(now: t0.addingTimeInterval(0.25))
        XCTAssertEqual(statuses.first { $0.id == "a" }?.userActive, true)
        XCTAssertEqual(statuses.first { $0.id == "a" }?.lastUserInputMsAgo, 250)
    }

    func testInputFromClientsAndSelfIsIgnored() {
        var state = PresenceState()
        state.openConnection(1, peerPID: 101)
        state.registerClient(1, pid: 111)
        _ = state.acquire(session: "a", targetPID: 900, holdMs: nil, connection: 1, now: t0)

        for source: pid_t in [101, 111, ownPID] {
            XCTAssertEqual(state.recordUserInput(sourcePID: source, targetPID: 900, isAbortChord: false, ownPID: ownPID, now: t0), .ignored)
        }
        XCTAssertFalse(state.isUserActive(session: "a", now: t0))

        // A client that just exited is still trusted for a short while.
        state.closeConnection(1, now: t0)
        XCTAssertEqual(state.recordUserInput(sourcePID: 111, targetPID: 900, isAbortChord: false, ownPID: ownPID, now: t0.addingTimeInterval(1)), .ignored)
        _ = state.sweep(now: t0.addingTimeInterval(10), isProcessAlive: alive)
        XCTAssertNotEqual(state.recordUserInput(sourcePID: 111, targetPID: 900, isAbortChord: false, ownPID: ownPID, now: t0.addingTimeInterval(10)), .ignored)
    }

    func testInputInUnleasedAppMarksNoSession() {
        var state = PresenceState()
        state.openConnection(1, peerPID: 101)
        _ = state.acquire(session: "a", targetPID: 900, holdMs: nil, connection: 1, now: t0)
        XCTAssertEqual(state.recordUserInput(sourcePID: 0, targetPID: 1, isAbortChord: false, ownPID: ownPID, now: t0), .recorded(sessions: []))
        XCTAssertFalse(state.isUserActive(session: "a", now: t0))
        XCTAssertEqual(state.lastUserInputAt, t0)
    }

    // MARK: Per-app input (finding: yield never fired on the first action)

    func testInputIsRecordedPerAppWithoutAnyLease() {
        var state = PresenceState()
        _ = state.recordUserInput(sourcePID: 0, targetPID: 900, isAbortChord: false, ownPID: ownPID, now: t0)
        _ = state.recordUserInput(sourcePID: 0, targetPID: 901, isAbortChord: false, ownPID: ownPID, now: t0.addingTimeInterval(0.3))
        XCTAssertEqual(state.appInputStatuses(now: t0.addingTimeInterval(0.5)), [
            AppInputStatus(pid: 901, lastInputMsAgo: 200),
            AppInputStatus(pid: 900, lastInputMsAgo: 500),
        ])
    }

    func testAmbientInputCountsGloballyButNotPerApp() {
        var state = PresenceState()
        _ = state.recordUserInput(sourcePID: 0, targetPID: 900, kind: .ambient, isAbortChord: false, ownPID: ownPID, now: t0)
        XCTAssertEqual(state.lastUserInputMsAgo(now: t0.addingTimeInterval(0.1)), 100)
        XCTAssertTrue(state.appInputStatuses(now: t0).isEmpty, "pointer motion does not say which app the user works in")
    }

    func testPerAppInputIsBoundedInCountAndAge() {
        var config = PresenceStateConfiguration()
        config.appInputLimit = 3
        config.appInputRetention = 10
        var state = PresenceState(configuration: config)
        for index in 0..<5 {
            _ = state.recordUserInput(sourcePID: 0, targetPID: pid_t(900 + index), isAbortChord: false, ownPID: ownPID, now: t0.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(state.appInputStatuses(now: t0.addingTimeInterval(4)).map(\.pid), [904, 903, 902])
        XCTAssertLessThanOrEqual(state.appInput.count, 4)
        _ = state.sweep(now: t0.addingTimeInterval(13.5), isProcessAlive: alive)
        XCTAssertEqual(state.appInput.keys.sorted(), [904])
    }

    func testClientInputIsNotRecordedPerApp() {
        var state = PresenceState()
        state.openConnection(1, peerPID: 101)
        XCTAssertEqual(state.recordUserInput(sourcePID: 101, targetPID: 900, isAbortChord: false, ownPID: ownPID, now: t0), .ignored)
        XCTAssertTrue(state.appInput.isEmpty)
        XCTAssertNil(state.lastUserInputAt)
    }

    // MARK: Abort

    func testAbortChordSetsAbortedUntilResume() {
        var state = PresenceState()
        state.setCursorState(.loading, session: "a", connection: nil, now: t0)
        XCTAssertEqual(state.recordUserInput(sourcePID: 0, targetPID: nil, isAbortChord: true, ownPID: ownPID, now: t0), .aborted)
        XCTAssertTrue(state.aborted)
        XCTAssertEqual(state.displayedState(session: "a"), .paused)
        state.resume()
        XCTAssertFalse(state.aborted)
        XCTAssertEqual(state.displayedState(session: "a"), .loading)
    }

    func testAcquireFailsWhileAborted() {
        var state = PresenceState()
        state.openConnection(1, peerPID: 101)
        _ = state.recordUserInput(sourcePID: 0, targetPID: nil, isAbortChord: true, ownPID: ownPID, now: t0)
        XCTAssertEqual(state.acquire(session: "a", targetPID: 900, holdMs: 0, connection: 1, now: t0).error?.code, .abortedByUser)
        XCTAssertTrue(state.leases.isEmpty)
    }

    func testAbortChordFromClientIsIgnored() {
        var state = PresenceState()
        state.openConnection(1, peerPID: 101)
        XCTAssertEqual(state.recordUserInput(sourcePID: 101, targetPID: nil, isAbortChord: true, ownPID: ownPID, now: t0), .ignored)
        XCTAssertFalse(state.aborted)
    }

    // MARK: Focus guard state

    func testGuardRestoresPreviousAppAndLimitsRestores() {
        var state = PresenceState()
        let begun = state.beginGuard(targetPID: 900, leaseMs: 2000, frontmostPID: 77, now: t0)
        XCTAssertEqual(begun.value?.previousFrontmostPID, 77)

        for _ in 0..<FocusGuardPolicy.maximumRestores {
            XCTAssertEqual(state.focusDecision(activatedPID: 900, now: t0.addingTimeInterval(1), secondsSinceHIDInput: nil), .restore(77))
        }
        XCTAssertEqual(state.focusDecision(activatedPID: 900, now: t0.addingTimeInterval(1), secondsSinceHIDInput: nil), .ignore(.restoreLimitReached))
    }

    func testStatusReportsWhenTheGuardLastRestored() {
        var state = PresenceState()
        _ = state.beginGuard(targetPID: 900, leaseMs: 3000, frontmostPID: 77, now: t0)
        XCTAssertEqual(state.guardRestoreStatuses(now: t0), [GuardRestoreStatus(pid: 900, restoreCount: 0, lastRestoreMsAgo: nil)])

        XCTAssertEqual(state.focusDecision(activatedPID: 900, now: t0.addingTimeInterval(1), secondsSinceHIDInput: nil), .restore(77))
        XCTAssertEqual(
            state.guardRestoreStatuses(now: t0.addingTimeInterval(1.25)),
            [GuardRestoreStatus(pid: 900, restoreCount: 1, lastRestoreMsAgo: 250)]
        )

        // A renewal for the next action keeps when the last restore happened.
        _ = state.beginGuard(targetPID: 900, leaseMs: 3000, frontmostPID: 77, now: t0.addingTimeInterval(1.5))
        XCTAssertEqual(state.guardRestoreStatuses(now: t0.addingTimeInterval(1.5)).first?.lastRestoreMsAgo, 500)
    }

    func testRenewedGuardSamplesTheFrontmostAppAgain() {
        var state = PresenceState()
        _ = state.beginGuard(targetPID: 900, leaseMs: 2000, frontmostPID: 77, now: t0)
        // The user moved from 77 to 78 between two actions.
        let renewed = state.beginGuard(targetPID: 900, leaseMs: 2000, frontmostPID: 78, now: t0.addingTimeInterval(1))
        XCTAssertEqual(renewed.value?.previousFrontmostPID, 78)
        XCTAssertEqual(
            state.focusDecision(activatedPID: 900, deactivatedPID: 78, now: t0.addingTimeInterval(2.5), secondsSinceHIDInput: nil),
            .restore(78),
            "never the app the user left"
        )
    }

    func testRenewalWhileTheTargetIsFrontmostLeavesNothingToRestore() {
        var state = PresenceState()
        _ = state.beginGuard(targetPID: 900, leaseMs: 2000, frontmostPID: 77, now: t0)
        _ = state.beginGuard(targetPID: 900, leaseMs: 2000, frontmostPID: 900, now: t0.addingTimeInterval(1))
        XCTAssertEqual(state.focusDecision(activatedPID: 900, deactivatedPID: 77, now: t0.addingTimeInterval(2.9), secondsSinceHIDInput: nil), .ignore(.nothingToRestore))
    }

    func testGuardPutsBackTheAppTheActivationTookFocusFrom() {
        var state = PresenceState()
        _ = state.beginGuard(targetPID: 900, leaseMs: 3000, frontmostPID: 77, now: t0)
        XCTAssertEqual(state.focusDecision(activatedPID: 900, deactivatedPID: 79, now: t0.addingTimeInterval(2.9), secondsSinceHIDInput: nil), .restore(79))
    }

    func testAnyKindOfRecentInputMeansTheUserCausedTheActivation() {
        for kind in [UserInputKind.deliberate, .ambient] {
            var state = PresenceState()
            _ = state.beginGuard(targetPID: 900, leaseMs: 5000, frontmostPID: 77, now: t0)
            // A scroll, a swipe, a held modifier, or pointer motion, in any app.
            _ = state.recordUserInput(sourcePID: 0, targetPID: nil, kind: kind, isAbortChord: false, ownPID: ownPID, now: t0.addingTimeInterval(1))
            XCTAssertEqual(state.focusDecision(activatedPID: 900, now: t0.addingTimeInterval(2.4), secondsSinceHIDInput: nil), .ignore(.userCaused), "\(kind)")
            XCTAssertNil(state.guards[900])
        }
    }

    func testSpaceChangeMeansTheUserCausedTheActivation() {
        var state = PresenceState()
        _ = state.beginGuard(targetPID: 900, leaseMs: 5000, frontmostPID: 77, now: t0)
        state.recordSpaceChange(now: t0.addingTimeInterval(1))
        XCTAssertEqual(state.focusDecision(activatedPID: 900, now: t0.addingTimeInterval(1.2), secondsSinceHIDInput: nil), .ignore(.userCaused))
    }

    func testGuardOnAlreadyFrontmostTargetHasNothingToRestore() {
        var state = PresenceState()
        _ = state.beginGuard(targetPID: 900, leaseMs: 2000, frontmostPID: 900, now: t0)
        XCTAssertEqual(state.focusDecision(activatedPID: 900, now: t0, secondsSinceHIDInput: nil), .ignore(.nothingToRestore))
    }

    func testUserCausedActivationEndsGuard() {
        var state = PresenceState()
        _ = state.beginGuard(targetPID: 900, leaseMs: 5000, frontmostPID: 77, now: t0)
        _ = state.recordUserInput(sourcePID: 0, targetPID: 77, isAbortChord: false, ownPID: ownPID, now: t0.addingTimeInterval(1))
        XCTAssertEqual(state.focusDecision(activatedPID: 900, now: t0.addingTimeInterval(1.2), secondsSinceHIDInput: nil), .ignore(.userCaused))
        XCTAssertNil(state.guards[900])
    }

    func testGuardLeaseIsCappedAndSwept() {
        var config = PresenceStateConfiguration()
        config.maximumGuardLease = 5
        var state = PresenceState(configuration: config)
        XCTAssertEqual(state.beginGuard(targetPID: 900, leaseMs: 60_000, frontmostPID: 77, now: t0).value?.leaseMs, 5000)
        _ = state.sweep(now: t0.addingTimeInterval(5), isProcessAlive: alive)
        XCTAssertTrue(state.guards.isEmpty)
        state.endGuard(targetPID: 900)
    }
}

final class FocusGuardPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func lease(previous: pid_t? = 77, expiresIn: TimeInterval = 2) -> FocusGuardLease {
        FocusGuardLease(targetPID: 900, previousFrontmostPID: previous, beganAt: t0.addingTimeInterval(-0.5), expiresAt: t0.addingTimeInterval(expiresIn))
    }

    private func decide(
        activated: pid_t = 900,
        deactivated: pid_t? = 77,
        at now: Date? = nil,
        lease: FocusGuardLease?,
        user: UserActivitySignals = UserActivitySignals()
    ) -> FocusGuardDecision {
        FocusGuardPolicy.decide(activatedPID: activated, deactivatedPID: deactivated, now: now ?? t0, guardLease: lease, user: user)
    }

    func testStealWithinLeaseIsUndone() {
        XCTAssertEqual(decide(lease: lease(), user: UserActivitySignals(secondsSinceHIDInput: 30)), .restore(77))
    }

    func testOtherAppsAreNotGuarded() {
        XCTAssertEqual(decide(activated: 901, lease: nil), .ignore(.notGuarded))
        XCTAssertEqual(decide(activated: 901, lease: lease()), .ignore(.notGuarded))
    }

    func testExpiredLeaseIsIgnored() {
        XCTAssertEqual(decide(at: t0.addingTimeInterval(2), lease: lease()), .ignore(.leaseExpired))
    }

    func testRecentTapInputMeansUserCausedIt() {
        XCTAssertEqual(decide(lease: lease(), user: UserActivitySignals(lastInputAt: t0.addingTimeInterval(-1.2))), .ignore(.userCaused))
        XCTAssertEqual(decide(lease: lease(), user: UserActivitySignals(lastInputAt: t0.addingTimeInterval(-2))), .restore(77))
    }

    func testRecentHIDInputMeansUserCausedItWithoutTap() {
        XCTAssertEqual(decide(lease: lease(), user: UserActivitySignals(secondsSinceHIDInput: 1.2)), .ignore(.userCaused))
        XCTAssertEqual(decide(lease: lease(), user: UserActivitySignals(secondsSinceHIDInput: 5)), .restore(77))
    }

    func testRecentSpaceChangeMeansUserCausedIt() {
        XCTAssertEqual(decide(lease: lease(), user: UserActivitySignals(lastSpaceChangeAt: t0.addingTimeInterval(-0.4))), .ignore(.userCaused))
    }

    func testNothingToRestore() {
        XCTAssertEqual(decide(lease: lease(previous: nil)), .ignore(.nothingToRestore))
    }

    func testRestoresTheDisplacedAppNotTheOneSampledAtBegin() {
        XCTAssertEqual(decide(deactivated: 88, lease: lease()), .restore(88))
        XCTAssertEqual(decide(deactivated: nil, lease: lease()), .restore(77), "unknown: the sampled app")
    }
}

private extension Result {
    var value: Success? {
        if case .success(let value) = self { return value }
        return nil
    }

    var error: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
