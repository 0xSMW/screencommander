import Foundation

/// Bounded session-local snapshots. Deltas describe positional records, not durable
/// element identity: callers must resolve IDs freshly before an action.
final class ElementSnapshotStore {
    private struct Entry {
        var scope: String
        var result: ElementsResult
        var bytes: Int
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let capacity: Int
    private let byteBudget: Int
    private var retainedBytes = 0

    init(capacity: Int = 8, byteBudget: Int = 8 * 1024 * 1024) {
        self.capacity = max(1, capacity)
        self.byteBudget = max(1, byteBudget)
    }

    func update(_ current: ElementsResult, request: ElementsRequest) -> ElementsResult {
        lock.lock()
        defer { lock.unlock() }
        var result = current
        let scope = Self.scope(current, request: request)
        let complete = !current.truncated && current.partialReason == nil
        let bytes = Self.estimatedBytes(current)
        guard bytes <= byteBudget else {
            result.resetReason = "snapshot_too_large"
            return result
        }
        if let since = request.since {
            if !complete {
                result.resetReason = "incomplete_read"
            } else if let baseline = entries[since], baseline.scope == scope {
                let previous = Dictionary(baseline.result.elements.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                let currentIds = Set(current.elements.map(\.id))
                result.elements = current.elements.filter { previous[$0.id] != $0 }
                result.removedIds = baseline.result.elements.map(\.id).filter { !currentIds.contains($0) }
                result.baseSnapshotId = since
                result.text = request.includeText ? AXTextRenderer.render(result.elements) : nil
            } else {
                result.resetReason = entries[since] == nil ? "snapshot_unavailable" : "scope_changed"
            }
        }
        // Never let an incomplete observation become an authoritative baseline.
        if complete {
            let id = UUID().uuidString.lowercased()
            result.snapshotId = id
            entries[id] = Entry(scope: scope, result: current, bytes: bytes)
            retainedBytes += bytes
            order.append(id)
            while order.count > capacity || retainedBytes > byteBudget {
                if let removed = entries.removeValue(forKey: order.removeFirst()) {
                    retainedBytes -= removed.bytes
                }
            }
        }
        return result
    }

    private static func estimatedBytes(_ result: ElementsResult) -> Int {
        result.elements.reduce((result.text?.utf8.count ?? 0) + 512) { total, record in
            total + 512 + [record.id, record.role, record.subrole, record.title, record.value, record.description]
                .compactMap { $0 }.reduce(0) { $0 + $1.utf8.count }
                + record.actions.reduce(0) { $0 + $1.utf8.count }
        }
    }

    private static func scope(_ result: ElementsResult, request: ElementsRequest) -> String {
        // Serialize scope components to avoid delimiter collisions in app names/roles.
        let components = [String(result.app.pid), result.app.bundleID ?? "", request.windowID.map(String.init) ?? "focused",
                          String(request.allWindows), String(request.maxDepth), String(request.maxElements),
                          (request.roles ?? []).sorted().joined(separator: ","), String(request.visibleOnly),
                          String(request.maxValueLength), request.profile.rawValue, String(request.includeText)]
        return (try? String(data: JSONEncoder().encode(components), encoding: .utf8)) ?? ""
    }
}
