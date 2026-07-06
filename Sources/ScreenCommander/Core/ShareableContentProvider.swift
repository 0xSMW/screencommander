import Foundation
import ScreenCaptureKit

/// Small time-based cache. Values fetched through `value(for:fetch:)` are reused
/// until the TTL lapses; a TTL of 0 disables caching entirely. Concurrent reads are
/// safe; concurrent *misses* may fetch redundantly — callers here (the MCP server
/// loop and one-shot CLI commands) are strictly sequential, so no single-flight
/// machinery is warranted.
final class TTLCache<Key: Hashable, Value> {
    private let ttl: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var entries: [Key: (value: Value, fetchedAt: Date)] = [:]

    init(ttl: TimeInterval, now: @escaping () -> Date = Date.init) {
        self.ttl = ttl
        self.now = now
    }

    func value(for key: Key, fetch: () async throws -> Value) async throws -> Value {
        if let cached = cachedValue(for: key) {
            return cached
        }
        // Errors are never cached: a failed enumeration must not poison later calls.
        let value = try await fetch()
        store(value, for: key)
        return value
    }

    private func cachedValue(for key: Key) -> Value? {
        guard ttl > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], now().timeIntervalSince(entry.fetchedAt) < ttl else {
            return nil
        }
        return entry.value
    }

    private func store(_ value: Value, for key: Key) {
        guard ttl > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        entries[key] = (value, now())
    }
}

/// Shared source of `SCShareableContent`. Enumeration costs ~100–300 ms per call; a
/// short TTL (serve mode uses 2 s) lets the persistent MCP server reuse one
/// enumeration across a burst of tool calls (`windows` → `screenshot --window` →
/// `click`). The CLI default is TTL 0 — every call fetches fresh, preserving one-shot
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
    func content(onScreenWindowsOnly: Bool) async throws -> SCShareableContent {
        try await cache.value(for: onScreenWindowsOnly) {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: onScreenWindowsOnly)
        }
    }
}
