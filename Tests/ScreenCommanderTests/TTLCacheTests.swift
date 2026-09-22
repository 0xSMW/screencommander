import Foundation
import XCTest
@testable import ScreenCommander

final class TTLCacheTests: XCTestCase {
    /// Mutable clock so tests control expiry deterministically.
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    private struct FetchError: Error {}

    /// The pre-single-flight TTL implementation, retained only as an A/B control.
    private final class LegacyTTLCache {
        private let lock = NSLock()
        private var entries: [Bool: (value: Int, fetchedAt: Date)] = [:]

        func value(for key: Bool, fetch: @Sendable () async throws -> Int) async throws -> Int {
            if let cached = cachedValue(for: key) { return cached }
            let value = try await fetch()
            store(value, for: key)
            return value
        }

        private func cachedValue(for key: Bool) -> Int? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[key], Date().timeIntervalSince(entry.fetchedAt) < 2 else { return nil }
            return entry.value
        }

        private func store(_ value: Int, for key: Bool) {
            lock.lock()
            entries[key] = (value, Date())
            lock.unlock()
        }
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private actor Gate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func open() {
            isOpen = true
            let pending = continuations
            continuations.removeAll()
            for continuation in pending { continuation.resume() }
        }
    }

    private func waitForWaiters(_ count: Int, key: Bool, cache: TTLCache<Bool, Int>) async throws {
        for _ in 0..<1_000 {
            if cache.inFlightWaiterCount(for: key) == count { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for \(count) coalesced requests")
    }

    private func waitForFetches(_ count: Int, counter: Counter) async throws {
        for _ in 0..<1_000 {
            if await counter.value == count { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for \(count) fetches")
    }

    func testReusesValueWithinTTL() async throws {
        let clock = Clock()
        let cache = TTLCache<Bool, Int>(ttl: 2, now: { clock.now })
        let counter = Counter()

        let first = try await cache.value(for: true) { await counter.increment(); return 7 }
        clock.now.addTimeInterval(1.5)
        let second = try await cache.value(for: true) { await counter.increment(); return 8 }
        let fetches = await counter.value

        XCTAssertEqual(first, 7)
        XCTAssertEqual(second, 7, "value inside the TTL window must come from cache")
        XCTAssertEqual(fetches, 1)
    }

    func testRefetchesAfterTTLExpires() async throws {
        let clock = Clock()
        let cache = TTLCache<Bool, Int>(ttl: 2, now: { clock.now })
        let counter = Counter()

        _ = try await cache.value(for: true) { await counter.increment(); return 7 }
        clock.now.addTimeInterval(2.1)
        let refreshed = try await cache.value(for: true) { await counter.increment(); return 8 }
        let fetches = await counter.value

        XCTAssertEqual(refreshed, 8)
        XCTAssertEqual(fetches, 2)
    }

    func testZeroTTLNeverCaches() async throws {
        let clock = Clock()
        let cache = TTLCache<Bool, Int>(ttl: 0, now: { clock.now })
        let counter = Counter()

        _ = try await cache.value(for: true) { await counter.increment(); return 1 }
        _ = try await cache.value(for: true) { await counter.increment(); return 2 }
        let fetches = await counter.value

        XCTAssertEqual(fetches, 2)
    }

    func testKeysAreCachedIndependently() async throws {
        let clock = Clock()
        let cache = TTLCache<Bool, Int>(ttl: 10, now: { clock.now })
        let counter = Counter()

        let onScreen = try await cache.value(for: true) { await counter.increment(); return 1 }
        let all = try await cache.value(for: false) { await counter.increment(); return 2 }
        let onScreenAgain = try await cache.value(for: true) { await counter.increment(); return 3 }
        let fetches = await counter.value

        XCTAssertEqual(onScreen, 1)
        XCTAssertEqual(all, 2)
        XCTAssertEqual(onScreenAgain, 1)
        XCTAssertEqual(fetches, 2)
    }

    func testErrorsAreNotCached() async throws {
        let clock = Clock()
        let cache = TTLCache<Bool, Int>(ttl: 10, now: { clock.now })
        let counter = Counter()

        do {
            _ = try await cache.value(for: true) { await counter.increment(); throw FetchError() }
            XCTFail("expected the fetch error to propagate")
        } catch is FetchError {}

        let recovered = try await cache.value(for: true) { await counter.increment(); return 9 }
        let fetches = await counter.value

        XCTAssertEqual(recovered, 9, "a failed fetch must not poison the cache")
        XCTAssertEqual(fetches, 2)
    }

    func testConcurrentMissesShareOneFetchAndExpireTogether() async throws {
        let clock = Clock()
        let cache = TTLCache<Bool, Int>(ttl: 2, now: { clock.now })
        let counter = Counter()
        let gate = Gate()
        let fetch: @Sendable () async throws -> Int = {
            await counter.increment()
            await gate.wait()
            return 17
        }
        let first = Task { try await cache.value(for: true, fetch: fetch) }
        try await waitForWaiters(1, key: true, cache: cache)
        let second = Task { try await cache.value(for: true, fetch: fetch) }
        try await waitForWaiters(2, key: true, cache: cache)
        await gate.open()
        let firstValue = try await first.value
        let secondValue = try await second.value
        let firstFetchCount = await counter.value
        XCTAssertEqual(firstValue, 17)
        XCTAssertEqual(secondValue, 17)
        XCTAssertEqual(firstFetchCount, 1)

        clock.now.addTimeInterval(2.1)
        let refreshed = try await cache.value(for: true) { await counter.increment(); return 23 }
        XCTAssertEqual(refreshed, 23)
        let totalFetchCount = await counter.value
        XCTAssertEqual(totalFetchCount, 2)
    }

    func testFailedFlightDoesNotPoisonConcurrentOrLaterRequests() async throws {
        let cache = TTLCache<Bool, Int>(ttl: 2)
        let counter = Counter()
        let gate = Gate()
        let fetch: @Sendable () async throws -> Int = {
            await counter.increment()
            await gate.wait()
            throw FetchError()
        }
        let first = Task { try await cache.value(for: true, fetch: fetch) }
        try await waitForWaiters(1, key: true, cache: cache)
        let second = Task { try await cache.value(for: true, fetch: fetch) }
        try await waitForWaiters(2, key: true, cache: cache)
        await gate.open()
        do { _ = try await first.value; XCTFail("first waiter should fail") } catch is FetchError {}
        do { _ = try await second.value; XCTFail("second waiter should fail") } catch is FetchError {}
        let failedFetchCount = await counter.value
        let recovered = try await cache.value(for: true) { await counter.increment(); return 19 }
        let totalFetchCount = await counter.value
        XCTAssertEqual(failedFetchCount, 1)
        XCTAssertEqual(recovered, 19)
        XCTAssertEqual(totalFetchCount, 2)
    }

    func testCanceledWaiterCannotCancelSharedFetch() async throws {
        let cache = TTLCache<Bool, Int>(ttl: 2)
        let counter = Counter()
        let gate = Gate()
        let fetch: @Sendable () async throws -> Int = {
            await counter.increment()
            await gate.wait()
            return 31
        }
        let first = Task { try await cache.value(for: true, fetch: fetch) }
        try await waitForWaiters(1, key: true, cache: cache)
        let second = Task { try await cache.value(for: true, fetch: fetch) }
        try await waitForWaiters(2, key: true, cache: cache)
        first.cancel()
        await gate.open()
        let secondValue = try await second.value
        do {
            _ = try await first.value
            XCTFail("The canceled waiter must not continue with a successful result")
        } catch is CancellationError {}
        let fetchCount = await counter.value
        let cached = try await cache.value(for: true) { 99 }
        XCTAssertEqual(secondValue, 31)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(cached, 31)
    }

    func testAlreadyCanceledRequestsDoNotFetchOrReadCachedValues() async throws {
        for ttl in [0.0, 2.0] {
            let cache = TTLCache<Bool, Int>(ttl: ttl)
            _ = try await cache.value(for: true) { 17 }
            for key in [true, false] {
                let gate = Gate(), counter = Counter()
                let caller = Task {
                    await gate.wait()
                    return try await cache.value(for: key) {
                        await counter.increment()
                        return 19
                    }
                }
                caller.cancel()
                await gate.open()
                do { _ = try await caller.value; XCTFail("Canceled caller should throw") }
                catch is CancellationError {}
                let fetchCount = await counter.value
                XCTAssertEqual(fetchCount, 0)
            }
        }
    }

    func testZeroTTLCancellationAfterFetchDoesNotReturnSuccess() async throws {
        let cache = TTLCache<Bool, Int>(ttl: 0)
        let gate = Gate(), counter = Counter()
        let caller = Task {
            try await cache.value(for: true) {
                await counter.increment()
                await gate.wait()
                return 23
            }
        }
        try await waitForFetches(1, counter: counter)
        caller.cancel()
        await gate.open()
        do { _ = try await caller.value; XCTFail("Canceled caller should throw after fetch") }
        catch is CancellationError {}
    }

    func testZeroTTLConcurrentMissesRemainIndependent() async throws {
        let cache = TTLCache<Bool, Int>(ttl: 0)
        let counter = Counter()
        let gate = Gate()
        let fetch: @Sendable () async throws -> Int = {
            await counter.increment()
            await gate.wait()
            return 41
        }
        let first = Task { try await cache.value(for: true, fetch: fetch) }
        let second = Task { try await cache.value(for: true, fetch: fetch) }
        for _ in 0..<1_000 {
            if await counter.value == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let fetchCount = await counter.value
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(cache.inFlightWaiterCount(for: true), 0)
        await gate.open()
        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual(firstValue, 41)
        XCTAssertEqual(secondValue, 41)
    }

    func testForcedRefreshSupersedesOldFlightAndCoalescesRefreshers() async throws {
        let cache = TTLCache<Bool, Int>(ttl: 10)
        let oldGate = Gate(), newGate = Gate()
        let oldCounter = Counter(), newCounter = Counter()
        let old = Task {
            try await cache.value(for: true) {
                await oldCounter.increment()
                await oldGate.wait()
                return 1
            }
        }
        try await waitForFetches(1, counter: oldCounter)

        let refresh: @Sendable () async throws -> Int = {
            await newCounter.increment()
            await newGate.wait()
            return 2
        }
        let firstRefresh = Task { try await cache.value(for: true, forceRefresh: true, fetch: refresh) }
        try await waitForFetches(1, counter: newCounter)
        let secondRefresh = Task { try await cache.value(for: true, forceRefresh: true, fetch: refresh) }
        try await waitForWaiters(2, key: true, cache: cache)
        await newGate.open()
        let firstFreshValue = try await firstRefresh.value
        let secondFreshValue = try await secondRefresh.value
        await oldGate.open()
        let oldValue = try await old.value
        let cached = try await cache.value(for: true) { 3 }
        let refreshFetchCount = await newCounter.value
        XCTAssertEqual(firstFreshValue, 2)
        XCTAssertEqual(secondFreshValue, 2)
        XCTAssertEqual(oldValue, 1)
        XCTAssertEqual(cached, 2, "late old flight must not overwrite the refresh")
        XCTAssertEqual(refreshFetchCount, 1)
    }

    func testInvalidateDiscardsCachedValueAndInFlightResult() async throws {
        let cache = TTLCache<Bool, Int>(ttl: 10)
        _ = try await cache.value(for: false) { 4 }
        cache.invalidate(key: false)
        let refreshed = try await cache.value(for: false) { 5 }
        XCTAssertEqual(refreshed, 5)

        let gate = Gate(), counter = Counter()
        let old = Task {
            try await cache.value(for: true) {
                await counter.increment()
                await gate.wait()
                return 6
            }
        }
        try await waitForFetches(1, counter: counter)
        cache.invalidate(key: true)
        let replacement = try await cache.value(for: true) { 7 }
        await gate.open()
        let oldValue = try await old.value
        let current = try await cache.value(for: true) { 8 }
        XCTAssertEqual(replacement, 7)
        XCTAssertEqual(oldValue, 6)
        XCTAssertEqual(current, 7)
    }

    func testSingleFlightFetchCountAB() async throws {
        guard ProcessInfo.processInfo.environment["SCREENCOMMANDER_PERF_AB"] == "1" else { return }
        let count = 20

        do {
            let cache = LegacyTTLCache()
            let counter = Counter(), gate = Gate()
            let fetch: @Sendable () async throws -> Int = {
                await counter.increment()
                await gate.wait()
                return 1
            }
            let start = ProcessInfo.processInfo.systemUptime
            let calls = (0..<count).map { _ in Task { try await cache.value(for: true, fetch: fetch) } }
            try await waitForFetches(count, counter: counter)
            await gate.open()
            for call in calls {
                let value = try await call.value
                XCTAssertEqual(value, 1)
            }
            let wall = ProcessInfo.processInfo.systemUptime - start
            let fetchCount = await counter.value
            print("SC_CAPTURE_ENUM_AB {\"variant\":\"legacy_ttl2\",\"ttl\":2,\"call_count\":\(count),\"fetch_count\":\(fetchCount),\"wall_s\":\(wall)}")
        }

        do {
            let cache = TTLCache<Bool, Int>(ttl: 2)
            let counter = Counter()
            let gate = Gate()
            let fetch: @Sendable () async throws -> Int = {
                await counter.increment()
                await gate.wait()
                return 1
            }
            let start = ProcessInfo.processInfo.systemUptime
            let calls = (0..<count).map { _ in Task { try await cache.value(for: true, fetch: fetch) } }
            try await waitForWaiters(count, key: true, cache: cache)
            await gate.open()
            for call in calls {
                let value = try await call.value
                XCTAssertEqual(value, 1)
            }
            let wall = ProcessInfo.processInfo.systemUptime - start
            let fetchCount = await counter.value
            print("SC_CAPTURE_ENUM_AB {\"variant\":\"singleflight_ttl2\",\"ttl\":2,\"call_count\":\(count),\"fetch_count\":\(fetchCount),\"wall_s\":\(wall)}")
        }

        // Separate guardrail: the CLI's TTL-0 path must remain fully fresh.
        do {
            let cache = TTLCache<Bool, Int>(ttl: 0)
            let counter = Counter(), gate = Gate()
            let fetch: @Sendable () async throws -> Int = {
                await counter.increment()
                await gate.wait()
                return 1
            }
            let start = ProcessInfo.processInfo.systemUptime
            let calls = (0..<count).map { _ in Task { try await cache.value(for: true, fetch: fetch) } }
            try await waitForFetches(count, counter: counter)
            await gate.open()
            for call in calls {
                let value = try await call.value
                XCTAssertEqual(value, 1)
            }
            let wall = ProcessInfo.processInfo.systemUptime - start
            let fetchCount = await counter.value
            print("SC_CAPTURE_ENUM_AB {\"variant\":\"fresh_ttl0\",\"ttl\":0,\"call_count\":\(count),\"fetch_count\":\(fetchCount),\"wall_s\":\(wall)}")
        }
    }
}
