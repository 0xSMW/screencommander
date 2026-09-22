import Foundation
import ScreenCaptureKit

/// Small time-based cache. Values fetched through `value(for:fetch:)` are reused
/// until the TTL lapses; a TTL of 0 disables caching entirely. Concurrent misses
/// for the same key share one independent fetch, without sharing waiter cancellation.
final class TTLCache<Key: Hashable, Value> {
    private struct SendableValue: @unchecked Sendable {
        let value: Value
    }

    private struct Flight {
        let id: UUID
        let task: Task<SendableValue, Error>
        let forcedRefresh: Bool
        var waiters: Int
    }

    private enum Lookup {
        case cached(Value)
        case flight(Flight)
    }

    private let ttl: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var entries: [Key: (value: Value, fetchedAt: Date)] = [:]
    private var flights: [Key: Flight] = [:]

    init(ttl: TimeInterval, now: @escaping () -> Date = Date.init) {
        self.ttl = ttl
        self.now = now
    }

    func value(
        for key: Key,
        forceRefresh: Bool = false,
        fetch: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard ttl > 0 else {
            let value = try await fetch()
            try Task.checkCancellation()
            return value
        }
        switch lookupOrStart(for: key, forceRefresh: forceRefresh, fetch: fetch) {
        case .cached(let value):
            try Task.checkCancellation()
            return value
        case .flight(let flight):
            // This task is not a child of a waiter. A canceled waiter cannot
            // cancel work another request is already awaiting.
            let result = await flight.task.result
            complete(flight, for: key, result: result)
            // Cache the shared producer's result, but never let a cancelled
            // caller continue into app activation or input delivery.
            try Task.checkCancellation()
            return try result.get().value
        }
    }

    private func lookupOrStart(
        for key: Key,
        forceRefresh: Bool,
        fetch: @escaping @Sendable () async throws -> Value
    ) -> Lookup {
        lock.lock()
        defer { lock.unlock() }
        if !forceRefresh,
           let entry = entries[key], now().timeIntervalSince(entry.fetchedAt) < ttl {
            return .cached(entry.value)
        }
        if var flight = flights[key] {
            if !forceRefresh || flight.forcedRefresh {
                flight.waiters += 1
                flights[key] = flight
                return .flight(flight)
            }
        }
        // A forced refresh supersedes the cached value and any ordinary flight.
        // Concurrent forced refreshes join the replacement flight.
        if forceRefresh { entries.removeValue(forKey: key) }
        let task = Task.detached { SendableValue(value: try await fetch()) }
        let flight = Flight(id: UUID(), task: task, forcedRefresh: forceRefresh, waiters: 1)
        flights[key] = flight
        return .flight(flight)
    }

    func invalidate(key: Key) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: key)
        // Do not cancel an in-flight producer: other waiters may still need it.
        // Removing its flight ensures its late completion cannot enter the cache.
        flights.removeValue(forKey: key)
    }

    private func complete(_ flight: Flight, for key: Key, result: Result<SendableValue, Error>) {
        lock.lock()
        defer { lock.unlock() }
        // A late waiter for an older flight must never replace a newer entry.
        guard flights[key]?.id == flight.id else { return }
        flights.removeValue(forKey: key)
        if case .success(let value) = result {
            entries[key] = (value.value, now())
        }
        // Errors are never cached: the next request gets a fresh fetch.
    }

    /// Internal visibility for deterministic concurrency tests.
    func inFlightWaiterCount(for key: Key) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return flights[key]?.waiters ?? 0
    }
}

/// Shared source of `SCShareableContent`. A short TTL (serve mode uses 2 s)
/// reuses each enumeration flavor across bursts of tool calls. Concurrent misses
/// share a producer; capture resolution can force refresh when geometry changes.
/// The CLI default is TTL 0 — every call fetches fresh, preserving one-shot
/// semantics (e.g. a `sequence` step that opens a window and immediately captures it
/// must see the new window).
final class ShareableContentProvider {
    private let cache: TTLCache<Bool, SCShareableContent>

    init(ttl: TimeInterval = 0, now: @escaping () -> Date = Date.init) {
        cache = TTLCache(ttl: ttl, now: now)
    }

    /// The two enumeration flavors used across the codebase, cached independently:
    /// on-screen-only (display resolution, window listing) and all-windows
    /// (window-capture resolution, which must find minimized/off-screen windows).
    func content(onScreenWindowsOnly: Bool, forceRefresh: Bool = false) async throws -> SCShareableContent {
        try await cache.value(for: onScreenWindowsOnly, forceRefresh: forceRefresh) {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: onScreenWindowsOnly)
        }
    }
}
