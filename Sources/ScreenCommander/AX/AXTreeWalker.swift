import CoreGraphics
import Foundation

/// Depth-first AX traversal. Filters select records while retaining traversal
/// through containers, which may contain matching descendants.
struct AXTreeWalker {
    var maxDepth: Int
    var maxElements: Int
    var roles: Set<String>?
    var visibleOnly: Bool
    var maxVisited: Int?
    var timeoutMS: Int?

    init(maxDepth: Int = 40, maxElements: Int = 2000, roles: [String]? = nil,
         visibleOnly: Bool = false, maxVisited: Int? = nil, timeoutMS: Int? = nil) {
        self.maxDepth = max(1, maxDepth)
        self.maxElements = max(1, maxElements)
        self.roles = roles.map { Set($0.map(Self.normalizeRole)) }
        self.visibleOnly = visibleOnly
        self.maxVisited = maxVisited.map { max(1, $0) }
        self.timeoutMS = timeoutMS.map { max(0, $0) }
    }

    struct WalkResult {
        var records: [AXElementRecord]
        var truncated: Bool
        var visitedCount: Int
        /// `max_elements`, `max_visited`, `timeout`, or `cancelled`.
        var partialReason: String?
    }

    private struct Frame<Node> {
        var node: Node
        var path: [Int]
        var depth: Int
        var visibleRect: CGRect?
        var visited = false
        var childCount = 0
        var nextOffset = 0
        var page: [(index: Int, node: Node)] = []
        var pageOffset = 0
    }

    /// Compatibility entry point for existing callers and synthetic trees.
    func walk<Node>(
        roots: [(path: [Int], node: Node, visibleRect: CGRect?)],
        children: (Node) -> [Node],
        record: (Node, _ id: String) -> AXElementRecord?
    ) -> WalkResult {
        walk(roots: roots,
             childCount: { children($0).count },
             childrenPage: { node, start, length in
                 let all = children(node)
                 guard start < all.count else { return [] }
                 return all[start..<min(all.count, start + length)].enumerated().map {
                     (index: start + $0.offset, node: $0.element)
                 }
             },
             record: record)
    }

    /// Paged traversal preserves original child indices. Cheap role and frame
    /// probes run before the more expensive `record` closure.
    func walk<Node>(
        roots: [(path: [Int], node: Node, visibleRect: CGRect?)],
        childCount: (Node) -> Int,
        childrenPage: (Node, _ start: Int, _ length: Int) -> [(index: Int, node: Node)],
        role: ((Node) -> String?)? = nil,
        frame: ((Node) -> CGRect?)? = nil,
        record: (Node, _ id: String) -> AXElementRecord?,
        deadlineNanos: UInt64? = nil,
        isCancelled: () -> Bool = { Task.isCancelled },
        nowNanos: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) -> WalkResult {
        let started = nowNanos()
        let deadline: UInt64? = deadlineNanos ?? timeoutMS.map { milliseconds in
            let duration = UInt64(milliseconds).multipliedReportingOverflow(by: 1_000_000)
            guard !duration.overflow else { return UInt64.max }
            let end = started.addingReportingOverflow(duration.partialValue)
            return end.overflow ? UInt64.max : end.partialValue
        }
        var records: [AXElementRecord] = []
        var visitedCount = 0
        var partialReason: String?
        var frames = roots.reversed().map {
            Frame(node: $0.node, path: $0.path, depth: 1, visibleRect: $0.visibleRect)
        }
        let pageSize = 128

        func interruption() -> String? {
            if isCancelled() { return "cancelled" }
            if let deadline, nowNanos() >= deadline { return "timeout" }
            return nil
        }

        while !frames.isEmpty {
            if let reason = interruption() {
                partialReason = reason
                break
            }
            let top = frames.count - 1
            if !frames[top].visited {
                if records.count >= maxElements { partialReason = "max_elements"; break }
                if let maxVisited, visitedCount >= maxVisited {
                    partialReason = "max_visited"
                    break
                }
                frames[top].visited = true
                visitedCount += 1
                let node = frames[top].node
                let visibleRect = frames[top].visibleRect
                var shouldEmit = true
                if let roles, let role {
                    shouldEmit = roles.contains(Self.normalizeRole(role(node) ?? "AXUnknown"))
                }
                if shouldEmit, visibleOnly, let visibleRect, let frame {
                    shouldEmit = frame(node).map(visibleRect.intersects) ?? false
                }
                if shouldEmit {
                    let id = frames[top].path.map(String.init).joined(separator: ".")
                    if let candidate = record(node, id),
                       passesFilters(candidate, visibleRect: visibleRect, visibilityChecked: frame != nil) {
                        records.append(candidate)
                    }
                }
                if frames[top].depth < maxDepth {
                    frames[top].childCount = max(0, childCount(node))
                }
                continue
            }

            if frames[top].pageOffset >= frames[top].page.count {
                if frames[top].nextOffset >= frames[top].childCount {
                    frames.removeLast()
                    continue
                }
                if records.count >= maxElements { partialReason = "max_elements"; break }
                if let maxVisited, visitedCount >= maxVisited {
                    partialReason = "max_visited"
                    break
                }
                let start = frames[top].nextOffset
                let length = min(pageSize, frames[top].childCount - start)
                frames[top].nextOffset += length
                frames[top].page = childrenPage(frames[top].node, start, length)
                frames[top].pageOffset = 0
                continue
            }

            if records.count >= maxElements { partialReason = "max_elements"; break }
            if let maxVisited, visitedCount >= maxVisited { partialReason = "max_visited"; break }
            let child = frames[top].page[frames[top].pageOffset]
            frames[top].pageOffset += 1
            frames.append(Frame(node: child.node, path: frames[top].path + [child.index],
                                depth: frames[top].depth + 1, visibleRect: frames[top].visibleRect))
        }

        return WalkResult(records: records, truncated: partialReason != nil,
                          visitedCount: visitedCount, partialReason: partialReason)
    }

    private func passesFilters(_ record: AXElementRecord, visibleRect: CGRect?,
                               visibilityChecked: Bool) -> Bool {
        if let roles, !roles.contains(Self.normalizeRole(record.role)) { return false }
        if visibleOnly, let visibleRect, !visibilityChecked {
            guard let bounds = record.boundsPoints, visibleRect.intersects(bounds.cgRect) else { return false }
        }
        return true
    }

    static func normalizeRole(_ role: String) -> String {
        let lowered = role.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered.hasPrefix("ax") ? String(lowered.dropFirst(2)) : lowered
    }
}
