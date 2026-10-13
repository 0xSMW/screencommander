import XCTest
@testable import ScreenCommander

final class PresenceRenewalIntervalTests: XCTestCase {
    func testRenewalUsesOneThirdOfIdlePeriod() {
        for idleMs in [500, PresencePolicy.defaultLeaseIdleMs, 600_000] {
            var policy = PresencePolicy()
            policy.leaseIdleMs = idleMs

            XCTAssertEqual(policy.leaseRenewInterval, Double(idleMs) / 3000, accuracy: 0.000_001)
            XCTAssertLessThan(policy.leaseRenewInterval, Double(idleMs) / 1000)
        }
    }

    func testResolvedIdlePeriodClampingPreservesRenewalMargin() {
        for (configured, expected) in [("1", 500), ("600001", 600_000)] {
            let policy = PresencePolicy.resolve(
                environment: ["SCREENCOMMANDER_LEASE_IDLE_MS": configured],
                serve: true
            )

            XCTAssertEqual(policy.leaseIdleMs, expected)
            XCTAssertEqual(policy.leaseRenewInterval, Double(expected) / 3000, accuracy: 0.000_001)
            XCTAssertLessThan(policy.leaseRenewInterval, Double(expected) / 1000)
        }
    }
}
