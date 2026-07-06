import CoreGraphics
import Foundation

/// Depth-first traversal of an accessibility tree with hard limits and output filters.
///
/// The walker is generic over the node type so the traversal logic (document order,
/// id-path assignment, depth/element limits, role and visibility filters) is unit
/// testable without a live `AXUIElement` tree. Filters affect which records are
/// *emitted*; children of filtered-out nodes are still visited, because containers
/// (e.g. `AXGroup`) often carry no text or role of interest themselves.
struct AXTreeWalker {
    /// Maximum id-path length (a root sits at depth 1).
    var maxDepth: Int
    /// Maximum number of emitted records; traversal stops once reached.
    var maxElements: Int
    /// Emit only records whose role matches (case-insensitive, optional "AX" prefix).
    var roles: Set<String>?
    /// Emit only records whose frame intersects the root's visible rect.
    var visibleOnly: Bool

    init(maxDepth: Int = 40, maxElements: Int = 2000, roles: [String]? = nil, visibleOnly: Bool = false) {
        self.maxDepth = max(1, maxDepth)
        self.maxElements = max(1, maxElements)
        self.roles = roles.map { Set($0.map(Self.normalizeRole)) }
        self.visibleOnly = visibleOnly
    }

    struct WalkResult {
        var records: [AXElementRecord]
        /// True when traversal stopped because `maxElements` was reached.
        var truncated: Bool
        /// Nodes visited, before filtering — used to detect empty/unusable trees.
        var visitedCount: Int
    }

    /// Walks each root in order. `path` is the child-index path of the root from the
    /// app element; `visibleRect` (usually the window frame) drives the visible-only
    /// filter for that root's subtree.
    func walk<Node>(
        roots: [(path: [Int], node: Node, visibleRect: CGRect?)],
        children: (Node) -> [Node],
        record: (Node, _ id: String) -> AXElementRecord?
    ) -> WalkResult {
        var records: [AXElementRecord] = []
        var visitedCount = 0
        var truncated = false
        var stack: [(node: Node, path: [Int], depth: Int, visibleRect: CGRect?)] = roots
            .reversed()
            .map { (node: $0.node, path: $0.path, depth: 1, visibleRect: $0.visibleRect) }

        while let item = stack.popLast() {
            guard records.count < maxElements else {
                truncated = true
                break
            }
            visitedCount += 1

            let id = item.path.map(String.init).joined(separator: ".")
            if let candidate = record(item.node, id), passesFilters(candidate, visibleRect: item.visibleRect) {
                records.append(candidate)
            }

            guard item.depth < maxDepth else {
                continue
            }
            for (index, child) in children(item.node).enumerated().reversed() {
                stack.append(
                    (
                        node: child,
                        path: item.path + [index],
                        depth: item.depth + 1,
                        visibleRect: item.visibleRect
                    )
                )
            }
        }

        return WalkResult(records: records, truncated: truncated, visitedCount: visitedCount)
    }

    private func passesFilters(_ record: AXElementRecord, visibleRect: CGRect?) -> Bool {
        if let roles, !roles.contains(Self.normalizeRole(record.role)) {
            return false
        }
        if visibleOnly, let visibleRect {
            guard let bounds = record.boundsPoints, visibleRect.intersects(bounds.cgRect) else {
                return false
            }
        }
        return true
    }

    /// Role matching accepts "AXButton", "button", or "Button" interchangeably.
    static func normalizeRole(_ role: String) -> String {
        let lowered = role.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered.hasPrefix("ax") ? String(lowered.dropFirst(2)) : lowered
    }
}
