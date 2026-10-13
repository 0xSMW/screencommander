import Foundation
import XCTest
@testable import ScreenCommanderPresence

final class KeepAwakeTests: XCTestCase {
    private final class FakeAssertion: PowerAssertionHolding {
        private(set) var takes = 0
        private(set) var releases = 0
        var held: Bool { takes > releases }

        func take() -> Bool {
            takes += 1
            return true
        }

        func release() {
            releases += 1
        }
    }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    private func makeCore(_ assertion: FakeAssertion?, clock: Clock) -> PresenceCore {
        PresenceCore(
            driver: HeadlessCursorDriver(),
            environment: PresenceEnvironment(now: { clock.now }, isProcessAlive: { _ in true }),
            keepAwake: KeepAwake(assertion: assertion)
        )
    }

    private func send(_ core: PresenceCore, _ request: PresenceRequest, id: UInt64 = 1) {
        core.handle(PresenceRequestEnvelope(id: id, request: request), connection: 1) { _ in }
    }

    func testAssertionFollowsTheSessionLifecycle() {
        let assertion = FakeAssertion()
        let clock = Clock()
        let core = makeCore(assertion, clock: clock)
        core.connectionOpened(1, peerPID: 42)
        XCTAssertFalse(assertion.held, "no session, no assertion")

        send(core, .sessionAcquire(SessionAcquireParams(session: "a", pid: 99, holdMs: 0)))
        XCTAssertTrue(assertion.held)
        XCTAssertEqual(core.status().keepAwake, true)

        send(core, .sessionAcquire(SessionAcquireParams(session: "b", pid: 98, holdMs: 0)), id: 2)
        XCTAssertEqual(assertion.takes, 1, "a second session does not take a second assertion")

        send(core, .sessionRelease(SessionReleaseParams(session: "a")), id: 3)
        XCTAssertTrue(assertion.held, "session b is still active")
        send(core, .sessionRelease(SessionReleaseParams(session: "b")), id: 4)
        XCTAssertFalse(assertion.held)
        XCTAssertEqual(core.status().keepAwake, false)
    }

    func testAssertionIsReleasedWhenTheLastSessionGoesIdleWhileItsClientStaysConnected() {
        let assertion = FakeAssertion()
        let clock = Clock()
        let core = makeCore(assertion, clock: clock)
        core.connectionOpened(1, peerPID: 42)
        send(core, .sessionAcquire(SessionAcquireParams(session: "a", pid: 99, holdMs: 0, idleMs: 15_000)))
        XCTAssertTrue(assertion.held)

        clock.now = clock.now.addingTimeInterval(14)
        core.tick()
        XCTAssertTrue(assertion.held)
        clock.now = clock.now.addingTimeInterval(1)
        core.tick()
        XCTAssertFalse(assertion.held, "an open connection does not keep the Mac awake")
        XCTAssertEqual(core.status().keepAwake, false)
    }

    func testAssertionOfAOneShotClientLastsUntilItsLeaseGoesIdle() {
        let assertion = FakeAssertion()
        let clock = Clock()
        let core = makeCore(assertion, clock: clock)
        core.connectionOpened(1, peerPID: 42)
        send(core, .sessionAcquire(SessionAcquireParams(session: "a", pid: 99, holdMs: 15_000, idleMs: 15_000)))
        core.connectionClosed(1)
        XCTAssertTrue(assertion.held, "the session keeps its app after its client exits")

        clock.now = clock.now.addingTimeInterval(15)
        core.tick()
        XCTAssertFalse(assertion.held)
    }

    func testAssertionIsReleasedAtOnceWhenAServeConnectionCloses() {
        let assertion = FakeAssertion()
        let core = makeCore(assertion, clock: Clock())
        core.connectionOpened(1, peerPID: 42)
        send(core, .sessionAcquire(SessionAcquireParams(session: "serve-1", pid: 99, holdMs: 0)))
        XCTAssertTrue(assertion.held)
        core.connectionClosed(1)
        XCTAssertFalse(assertion.held)
        XCTAssertTrue(core.status().sessions.isEmpty)
    }

    func testStopAndShutdownReleaseTheAssertion() {
        let assertion = FakeAssertion()
        let core = makeCore(assertion, clock: Clock())
        core.connectionOpened(1, peerPID: 42)
        send(core, .sessionAcquire(SessionAcquireParams(session: "a", pid: 99, holdMs: 0)))
        XCTAssertTrue(assertion.held)
        send(core, .hello(HelloParams(pid: 42)), id: 5)
        send(core, .shutdown, id: 2)
        XCTAssertFalse(assertion.held, "shutdown releases even with a session left")

        let other = FakeAssertion()
        let second = makeCore(other, clock: Clock())
        second.connectionOpened(1, peerPID: 42)
        send(second, .sessionAcquire(SessionAcquireParams(session: "a", pid: 99, holdMs: 0)))
        second.stop()
        XCTAssertFalse(other.held)
    }

    func testEnvironmentVariableTurnsKeepAwakeOff() {
        XCTAssertTrue(KeepAwake.isEnabled(environment: [:]))
        XCTAssertTrue(KeepAwake.isEnabled(environment: ["SCREENCOMMANDER_KEEP_AWAKE": "1"]))
        for value in ["0", "false", "NO", " off "] {
            XCTAssertFalse(KeepAwake.isEnabled(environment: ["SCREENCOMMANDER_KEEP_AWAKE": value]), value)
        }
        XCTAssertFalse(KeepAwake.live(environment: ["SCREENCOMMANDER_KEEP_AWAKE": "0"]).isEnabled)

        let core = PresenceCore(driver: HeadlessCursorDriver(), keepAwake: KeepAwake(assertion: nil))
        core.connectionOpened(1, peerPID: 42)
        send(core, .sessionAcquire(SessionAcquireParams(session: "a", pid: 99, holdMs: 0)))
        XCTAssertNil(core.status().keepAwake, "off reports no assertion state")
    }

    func testActivityKeepAwakeReleasesAfterTheIdleWindow() {
        let assertion = FakeAssertion()
        let clock = Clock()
        let activity = ActivityKeepAwake(keepAwake: KeepAwake(assertion: assertion), idleWindow: 120, now: { clock.now })

        activity.tick()
        XCTAssertFalse(assertion.held)
        activity.noteActivity()
        XCTAssertTrue(assertion.held)
        clock.now = clock.now.addingTimeInterval(60)
        activity.tick()
        XCTAssertTrue(assertion.held)
        clock.now = clock.now.addingTimeInterval(61)
        activity.tick()
        XCTAssertFalse(assertion.held)
        activity.noteActivity()
        activity.stop()
        XCTAssertFalse(assertion.held)
    }
}
