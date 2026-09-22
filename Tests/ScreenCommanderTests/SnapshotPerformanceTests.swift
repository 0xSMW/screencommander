import Foundation
import XCTest
@testable import ScreenCommander

final class SnapshotPerformanceTests: XCTestCase {
    private func result(_ records: [AXElementRecord], truncated: Bool = false) -> ElementsResult {
        ElementsResult(app: ResolvedApp(pid: 123, name: "Fixture", bundleID: nil), windowID: nil,
                       metadataPath: nil, axPrimed: false, truncated: truncated, elements: records, text: nil)
    }

    func testDeltaReconstructsFullObservationIncludingRemovalsAndChanges() throws {
        let store = ElementSnapshotStore()
        let original = [AXElementRecord(id: "0", role: "AXWindow", title: "Window"),
                        AXElementRecord(id: "0.1", role: "AXButton", title: "Save"),
                        AXElementRecord(id: "0.2", role: "AXTextField", value: "old")]
        let base = store.update(result(original), request: ElementsRequest(snapshot: true))
        let changed = [original[0], AXElementRecord(id: "0.2", role: "AXTextField", value: "new"),
                       AXElementRecord(id: "0.3", role: "AXButton", title: "Done")]
        let delta = store.update(result(changed), request: ElementsRequest(since: base.snapshotId))
        XCTAssertEqual(delta.baseSnapshotId, base.snapshotId)
        XCTAssertEqual(delta.removedIds, ["0.1"])
        XCTAssertEqual(delta.elements.map(\.id), ["0.2", "0.3"])
        var reconstructed = Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0) })
        for id in delta.removedIds ?? [] { reconstructed.removeValue(forKey: id) }
        for record in delta.elements { reconstructed[record.id] = record }
        XCTAssertEqual(reconstructed, Dictionary(uniqueKeysWithValues: changed.map { ($0.id, $0) }))
    }

    func testIncompleteReadNeverBecomesBaselineOrClaimsRemoval() {
        let store = ElementSnapshotStore()
        let base = store.update(result([AXElementRecord(id: "0", role: "AXWindow")]), request: ElementsRequest(snapshot: true))
        let partial = store.update(result([], truncated: true), request: ElementsRequest(since: base.snapshotId))
        XCTAssertEqual(partial.resetReason, "incomplete_read")
        XCTAssertNil(partial.snapshotId)
        XCTAssertNil(partial.removedIds)
        XCTAssertNil(partial.baseSnapshotId)
    }

    func testEvictionAndScopeChangesReturnFullReset() {
        let store = ElementSnapshotStore(capacity: 1)
        let current = result([AXElementRecord(id: "0", role: "AXWindow")])
        let first = store.update(current, request: ElementsRequest(snapshot: true))
        let second = store.update(current, request: ElementsRequest(snapshot: true))
        let scoped = store.update(current, request: ElementsRequest(profile: .text, since: second.snapshotId))
        XCTAssertEqual(scoped.resetReason, "scope_changed")
        XCTAssertEqual(scoped.elements, current.elements)
        let evicted = store.update(current, request: ElementsRequest(since: first.snapshotId))
        XCTAssertEqual(evicted.resetReason, "snapshot_unavailable")
        XCTAssertEqual(evicted.elements, current.elements)
    }

    func testOversizedSnapshotIsNotRetained() {
        let store = ElementSnapshotStore(byteBudget: 1024)
        let oversized = result([AXElementRecord(id: "0", role: "AXTextField", value: String(repeating: "x", count: 4096))])
        let response = store.update(oversized, request: ElementsRequest(snapshot: true))
        XCTAssertNil(response.snapshotId)
        XCTAssertEqual(response.resetReason, "snapshot_too_large")
        XCTAssertEqual(response.elements, oversized.elements)
    }

    func testABSnapshotWireBytes() throws {
        guard ProcessInfo.processInfo.environment["SCREENCOMMANDER_PERF_AB"] == "1" else { throw XCTSkip("Opt-in A/B benchmark") }
        let records = (0..<2000).map { index in
            AXElementRecord(id: "0.\(index)", role: "AXTextField", title: "Fixture field \(index)", value: "Stable value \(index)",
                            enabled: true, focused: false, actions: ["AXConfirm"],
                            boundsPoints: RectD(x: 20, y: Double(index * 24), w: 400, h: 24))
        }
        let store = ElementSnapshotStore()
        let baseline = store.update(result(records), request: ElementsRequest(snapshot: true))
        var updated = records
        for index in stride(from: 0, to: records.count, by: 100) { updated[index].value = "Changed value \(index)" }
        let full = result(updated)
        let delta = store.update(full, request: ElementsRequest(since: baseline.snapshotId))
        func wire(_ result: ElementsResult) throws -> Int {
            let envelope = try JSONValue(encoding: CommandEnvelope(status: "ok", command: "elements", result: result, exitCode: 0))
            let value = JSONValue.object(["structuredContent": envelope, "content": .array([.object(["type": .string("text"), "text": .string(try envelope.compactLine())])]), "isError": .bool(false)])
            return try value.compactLine().utf8.count
        }
        let a = try wire(full), b = try wire(delta)
        XCTAssertEqual(delta.elements.count, 20)
        XCTAssertLessThan(b, a / 20)
        print("SC_PERF_AB " + (try JSONValue.object(["case": .string("snapshot_wire_2000_nodes_1_percent_changed"),
              "baseline_bytes": .number(Double(a)), "candidate_bytes": .number(Double(b)),
              "baseline_records": .number(2000), "candidate_records": .number(20),
              "note": .string("Same full AX read; measures response bytes, not AX latency.")]).compactLine()))
    }
}
