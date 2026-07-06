import Foundation
import XCTest
@testable import ScreenCommander

final class TTLCacheTests: XCTestCase {
    /// Mutable clock so tests control expiry deterministically.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    private struct FetchError: Error {}

    func testReusesValueWithinTTL() async throws {
        let clock = Clock()
        let cache = TTLCache<Bool, Int>(ttl: 2, now: { clock.now })
        var fetches = 0

        let first = try await cache.value(for: true) { fetches += 1; return 7 }
        clock.now.addTimeInterval(1.5)
        let second = try await cache.value(for: true) { fetches += 1; return 8 }

        XCTAssertEqual(first, 7)
        XCTAssertEqual(second, 7, "value inside the TTL window must come from cache")
        XCTAssertEqual(fetches, 1)
    }

    func testRefetchesAfterTTLExpires() async throws {
        let clock = Clock()
        let cache = TTLCache<Bool, Int>(ttl: 2, now: { clock.now })
        var fetches = 0

        _ = try await cache.value(for: true) { fetches += 1; return 7 }
        clock.now.addTimeInterval(2.1)
        let refreshed = try await cache.value(for: true) { fetches += 1; return 8 }

        XCTAssertEqual(refreshed, 8)
        XCTAssertEqual(fetches, 2)
    }

    func testZeroTTLNeverCaches() async throws {
        let clock = Clock()
        let cache = TTLCache<Bool, Int>(ttl: 0, now: { clock.now })
        var fetches = 0

        _ = try await cache.value(for: true) { fetches += 1; return 1 }
        _ = try await cache.value(for: true) { fetches += 1; return 2 }

        XCTAssertEqual(fetches, 2)
    }

    func testKeysAreCachedIndependently() async throws {
        let clock = Clock()
        let cache = TTLCache<Bool, Int>(ttl: 10, now: { clock.now })
        var fetches = 0

        let onScreen = try await cache.value(for: true) { fetches += 1; return 1 }
        let all = try await cache.value(for: false) { fetches += 1; return 2 }
        let onScreenAgain = try await cache.value(for: true) { fetches += 1; return 3 }

        XCTAssertEqual(onScreen, 1)
        XCTAssertEqual(all, 2)
        XCTAssertEqual(onScreenAgain, 1)
        XCTAssertEqual(fetches, 2)
    }

    func testErrorsAreNotCached() async throws {
        let clock = Clock()
        let cache = TTLCache<Bool, Int>(ttl: 10, now: { clock.now })
        var fetches = 0

        do {
            _ = try await cache.value(for: true) { fetches += 1; throw FetchError() }
            XCTFail("expected the fetch error to propagate")
        } catch is FetchError {}

        let recovered = try await cache.value(for: true) { fetches += 1; return 9 }

        XCTAssertEqual(recovered, 9, "a failed fetch must not poison the cache")
        XCTAssertEqual(fetches, 2)
    }
}
