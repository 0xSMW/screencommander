import CoreGraphics
import Foundation
import ApplicationServices
import XCTest
@testable import ScreenCommander

private final class AXFixtureNode {
    let role: String
    let frame: CGRect?
    var children: [AXFixtureNode]

    init(_ role: String, frame: CGRect? = nil, children: [AXFixtureNode] = []) {
        self.role = role
        self.frame = frame
        self.children = children
    }
}

final class AXPerformanceTests: XCTestCase {
    func testDirectPathReturnsSameRecordAsFullTraversalWithFewerNodeReads() throws {
        let leaves = (0..<300).map { _ in AXFixtureNode("AXButton", children: []) }
        let root = AXFixtureNode("AXWindow", children: leaves)
        var fullHydrations = 0
        let full = AXTreeWalker(maxElements: 1000).walk(
            roots: [(path: [2], node: root, visibleRect: nil)],
            childCount: { $0.children.count },
            childrenPage: { node, start, length in
                node.children[start..<min(node.children.count, start + length)].enumerated().map {
                    (index: start + $0.offset, node: $0.element)
                }
            },
            record: { node, id in
                fullHydrations += 1
                return AXElementRecord(id: id, role: node.role)
            }
        )
        let oldRecord = try XCTUnwrap(full.records.first(where: { $0.id == "2.299" }))
        var directChildReads = 0
        let resolved: AXFixtureNode? = try AXReader.resolvePath(
            id: "2.299", roots: [(path: [2], node: root)],
            childAt: { node, index in
                directChildReads += 1
                return node.children.indices.contains(index) ? node.children[index] : nil
            }
        )
        let newRecord = AXElementRecord(id: "2.299", role: try XCTUnwrap(resolved).role)

        XCTAssertEqual(newRecord, oldRecord)
        XCTAssertEqual(fullHydrations, 301)
        XCTAssertEqual(directChildReads, 1)
    }

    func testDirectPathRejectsOutOfScopeAndStaleIDs() throws {
        let root = AXFixtureNode("AXWindow", children: [AXFixtureNode("AXButton")])
        XCTAssertNil(try AXReader.resolvePath(id: "1.0", roots: [(path: [2], node: root)],
                                              childAt: { $0.children[$1] }))
        XCTAssertNil(try AXReader.resolvePath(id: "2.5", roots: [(path: [2], node: root)],
                                              childAt: { node, index in
                                                  node.children.indices.contains(index) ? node.children[index] : nil
                                              }))
        XCTAssertThrowsError(try AXReader.resolvePath(id: "2..0", roots: [(path: [2], node: root)],
                                                        childAt: { _, _ in nil }))
    }

    func testCheapFiltersRetainDescendantsAndAvoidRecordHydration() {
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        let root = AXFixtureNode("AXWindow", frame: window, children: [
            AXFixtureNode("AXGroup", frame: CGRect(x: 200, y: 200, width: 10, height: 10), children: [
                AXFixtureNode("AXButton", frame: CGRect(x: 10, y: 10, width: 10, height: 10))
            ]),
            AXFixtureNode("AXButton", frame: CGRect(x: 300, y: 300, width: 10, height: 10))
        ])
        var hydrations = 0
        let result = AXTreeWalker(roles: ["button"], visibleOnly: true).walk(
            roots: [(path: [0], node: root, visibleRect: window)],
            childCount: { $0.children.count },
            childrenPage: { node, start, length in
                node.children[start..<min(node.children.count, start + length)].enumerated().map {
                    (index: start + $0.offset, node: $0.element)
                }
            },
            role: { $0.role }, frame: { $0.frame },
            record: { node, id in
                hydrations += 1
                return AXElementRecord(id: id, role: node.role,
                                       boundsPoints: node.frame.map(RectD.init))
            }
        )
        XCTAssertEqual(result.records.map(\.id), ["0.0.0"])
        XCTAssertEqual(result.visitedCount, 4)
        XCTAssertEqual(hydrations, 1)

        let textProfile = AXTreeWalker(roles: ["button"], visibleOnly: true).walk(
            roots: [(path: [0], node: root, visibleRect: window)],
            childCount: { $0.children.count },
            childrenPage: { node, start, length in
                node.children[start..<min(node.children.count, start + length)].enumerated().map {
                    (index: start + $0.offset, node: $0.element)
                }
            },
            role: { $0.role }, frame: { $0.frame },
            record: { node, id in AXElementRecord(id: id, role: node.role) }
        )
        XCTAssertEqual(textProfile.records.map(\.id), ["0.0.0"])
    }

    func testPagingPreservesOriginalIndicesAndVisitedBudgetStopsFurtherPages() {
        let root = AXFixtureNode("AXWindow", children: (0..<300).map { _ in AXFixtureNode("AXButton") })
        var requestedStarts: [Int] = []
        let result = AXTreeWalker(maxVisited: 3).walk(
            roots: [(path: [4], node: root, visibleRect: nil)],
            childCount: { $0.children.count },
            childrenPage: { node, start, length in
                requestedStarts.append(start)
                // Simulate an AX page containing a non-element entry at index 1.
                return node.children[start..<min(node.children.count, start + length)].enumerated().compactMap {
                    let index = start + $0.offset
                    return index == 1 ? nil : (index: index, node: $0.element)
                }
            },
            record: { node, id in AXElementRecord(id: id, role: node.role) }
        )
        XCTAssertEqual(result.records.map(\.id), ["4", "4.0", "4.2"])
        XCTAssertEqual(result.visitedCount, 3)
        XCTAssertEqual(result.partialReason, "max_visited")
        XCTAssertEqual(requestedStarts, [0])
    }

    func testTimeoutAndCancellationReportPartialReason() {
        let root = AXFixtureNode("AXWindow")
        let timeout = AXTreeWalker(timeoutMS: 0).walk(
            roots: [(path: [0], node: root, visibleRect: nil)],
            childCount: { _ in 0 }, childrenPage: { _, _, _ in [] },
            record: { _, id in AXElementRecord(id: id, role: "AXWindow") },
            isCancelled: { false }, nowNanos: { 10 }
        )
        XCTAssertEqual(timeout.partialReason, "timeout")
        XCTAssertEqual(timeout.visitedCount, 0)

        let cancelled = AXTreeWalker().walk(
            roots: [(path: [0], node: root, visibleRect: nil)],
            childCount: { _ in 0 }, childrenPage: { _, _, _ in [] },
            record: { _, id in AXElementRecord(id: id, role: "AXWindow") },
            isCancelled: { true }
        )
        XCTAssertEqual(cancelled.partialReason, "cancelled")

        let inheritedDeadline = AXTreeWalker().walk(
            roots: [(path: [0], node: root, visibleRect: nil)],
            childCount: { _ in 0 }, childrenPage: { _, _, _ in [] },
            record: { _, id in AXElementRecord(id: id, role: "AXWindow") },
            deadlineNanos: 9, isCancelled: { false }, nowNanos: { 10 }
        )
        XCTAssertEqual(inheritedDeadline.partialReason, "timeout")
    }

    func testMissingOrShortExpectedChildPageIsIncomplete() {
        for received in [nil, 0, 2] as [Int?] {
            let diagnostics = AXReadDiagnostics()
            diagnostics.validatePage(receivedCount: received, requestedCount: 3)
            XCTAssertTrue(diagnostics.hadTransientError)
        }
        let complete = AXReadDiagnostics()
        complete.validatePage(receivedCount: 3, requestedCount: 3)
        XCTAssertFalse(complete.hadTransientError)
    }

    func testTransientAXErrorsAreDistinguishedFromUnsupportedAttributes() {
        let diagnostics = AXReadDiagnostics()
        diagnostics.record(.attributeUnsupported)
        diagnostics.record(.noValue)
        diagnostics.record(.parameterizedAttributeUnsupported)
        XCTAssertFalse(diagnostics.hadTransientError)
        diagnostics.record(.cannotComplete)
        XCTAssertTrue(diagnostics.hadTransientError)
    }

    func testRangedTextUsesUTF16OffsetsAndFallsBackOnIncompleteGrapheme() {
        let text = String(repeating: "😀", count: 100)
        var requestedUnits = 0
        let shortened = AXReader.rangedTextValue(characterCount: (text as NSString).length,
                                                 maxValueLength: 3) { length in
            requestedUnits = length
            return (text as NSString).substring(with: NSRange(location: 0, length: length))
        }
        XCTAssertEqual(shortened?.value, "😀😀😀")
        XCTAssertEqual(shortened?.truncated, true)
        XCTAssertEqual(requestedUnits, 64)

        let combining = "a" + String(repeating: "\u{0301}", count: 100) + "z"
        let fallback = AXReader.rangedTextValue(characterCount: (combining as NSString).length,
                                                maxValueLength: 1) { length in
            (combining as NSString).substring(with: NSRange(location: 0, length: length))
        }
        XCTAssertNil(fallback)
    }
}
