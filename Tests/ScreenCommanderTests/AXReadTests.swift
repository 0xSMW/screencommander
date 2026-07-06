import CoreGraphics
import Foundation
import XCTest
@testable import ScreenCommander

/// Simple value tree standing in for live AXUIElements in walker tests.
private struct TestNode {
    var role: String
    var title: String?
    var value: String?
    var frame: CGRect?
    var children: [TestNode] = []
}

private func walk(
    _ walker: AXTreeWalker,
    roots: [(path: [Int], node: TestNode, visibleRect: CGRect?)]
) -> AXTreeWalker.WalkResult {
    walker.walk(roots: roots) { node in
        node.children
    } record: { node, id in
        AXElementRecord(
            id: id,
            role: node.role,
            title: node.title,
            value: node.value,
            boundsPoints: node.frame.map(RectD.init)
        )
    }
}

final class AXTreeWalkerTests: XCTestCase {
    private var sampleTree: TestNode {
        TestNode(role: "AXWindow", title: "Main", children: [
            TestNode(role: "AXGroup", children: [
                TestNode(role: "AXButton", title: "OK"),
                TestNode(role: "AXButton", title: "Cancel")
            ]),
            TestNode(role: "AXTextField", value: "query")
        ])
    }

    func testDepthFirstOrderAndIDPaths() {
        let result = walk(AXTreeWalker(), roots: [(path: [2], node: sampleTree, visibleRect: nil)])

        XCTAssertEqual(result.records.map(\.id), ["2", "2.0", "2.0.0", "2.0.1", "2.1"])
        XCTAssertEqual(result.records.map(\.role), ["AXWindow", "AXGroup", "AXButton", "AXButton", "AXTextField"])
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.visitedCount, 5)
    }

    func testMaxDepthStopsDescent() {
        let result = walk(
            AXTreeWalker(maxDepth: 2),
            roots: [(path: [0], node: sampleTree, visibleRect: nil)]
        )

        XCTAssertEqual(result.records.map(\.id), ["0", "0.0", "0.1"])
    }

    func testMaxElementsTruncates() {
        let result = walk(
            AXTreeWalker(maxElements: 3),
            roots: [(path: [0], node: sampleTree, visibleRect: nil)]
        )

        XCTAssertEqual(result.records.map(\.id), ["0", "0.0", "0.0.0"])
        XCTAssertTrue(result.truncated)
    }

    func testExactElementCountIsNotMarkedTruncated() {
        let result = walk(
            AXTreeWalker(maxElements: 5),
            roots: [(path: [0], node: sampleTree, visibleRect: nil)]
        )

        XCTAssertEqual(result.records.count, 5)
        XCTAssertFalse(result.truncated)
    }

    func testRoleFilterEmitsOnlyMatchesButStillTraversesChildren() {
        let result = walk(
            AXTreeWalker(roles: ["button"]),
            roots: [(path: [0], node: sampleTree, visibleRect: nil)]
        )

        XCTAssertEqual(result.records.map(\.id), ["0.0.0", "0.0.1"])
        XCTAssertEqual(result.visitedCount, 5)
    }

    func testRoleFilterMatchesWithAndWithoutAXPrefixCaseInsensitively() {
        for spelling in ["AXButton", "axbutton", "Button", "BUTTON"] {
            let result = walk(
                AXTreeWalker(roles: [spelling]),
                roots: [(path: [0], node: sampleTree, visibleRect: nil)]
            )
            XCTAssertEqual(result.records.count, 2, "roles filter '\(spelling)' should match AXButton")
        }
    }

    func testVisibleOnlySkipsOffscreenAndFramelessRecords() {
        let tree = TestNode(role: "AXWindow", frame: CGRect(x: 0, y: 0, width: 100, height: 100), children: [
            TestNode(role: "AXButton", title: "In", frame: CGRect(x: 10, y: 10, width: 20, height: 20)),
            TestNode(role: "AXButton", title: "Out", frame: CGRect(x: 500, y: 500, width: 20, height: 20)),
            TestNode(role: "AXGroup")
        ])

        let result = walk(
            AXTreeWalker(visibleOnly: true),
            roots: [(path: [0], node: tree, visibleRect: CGRect(x: 0, y: 0, width: 100, height: 100))]
        )

        XCTAssertEqual(result.records.map(\.title), [nil, "In"])
    }

    func testMultipleRootsWalkInOrder() {
        let result = walk(
            AXTreeWalker(),
            roots: [
                (path: [1], node: TestNode(role: "AXWindow", title: "A"), visibleRect: nil),
                (path: [3], node: TestNode(role: "AXWindow", title: "B"), visibleRect: nil)
            ]
        )

        XCTAssertEqual(result.records.map(\.id), ["1", "3"])
    }
}

final class AXElementRecordTests: XCTestCase {
    func testDepthDerivedFromIDPath() {
        XCTAssertEqual(AXElementRecord(id: "0", role: "AXWindow").depth, 0)
        XCTAssertEqual(AXElementRecord(id: "0.3", role: "AXGroup").depth, 1)
        XCTAssertEqual(AXElementRecord(id: "0.3.2", role: "AXButton").depth, 2)
        XCTAssertEqual(AXElementRecord(id: "", role: "AXApplication").depth, 0)
    }

    func testValueTruncationMarker() {
        let (short, shortTruncated) = AXElementRecord.truncatedValue("hello", maxLength: 200)
        XCTAssertEqual(short, "hello")
        XCTAssertFalse(shortTruncated)

        let (long, longTruncated) = AXElementRecord.truncatedValue("hello world", maxLength: 5)
        XCTAssertEqual(long, "hello")
        XCTAssertTrue(longTruncated)

        let (exact, exactTruncated) = AXElementRecord.truncatedValue("hello", maxLength: 5)
        XCTAssertEqual(exact, "hello")
        XCTAssertFalse(exactTruncated)
    }

    func testRecordRoundTripsThroughJSONWithStableKeys() throws {
        let record = AXElementRecord(
            id: "0.3.2",
            role: "AXButton",
            subrole: "AXCloseButton",
            title: "Close",
            value: "v",
            valueTruncated: true,
            description: "close button",
            enabled: false,
            focused: true,
            actions: ["AXPress"],
            boundsPoints: RectD(x: 1, y: 2, w: 3, h: 4),
            boundsPixels: RectD(x: 2, y: 4, w: 6, h: 8)
        )

        let data = try JSONEncoder().encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["id", "role", "subrole", "title", "value", "valueTruncated", "description",
                    "enabled", "focused", "actions", "boundsPoints", "boundsPixels"] {
            XCTAssertNotNil(object[key], "missing JSON key '\(key)'")
        }

        let decoded = try JSONDecoder().decode(AXElementRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }
}

final class AXTextRendererTests: XCTestCase {
    func testRendersIndentedTreeAndSkipsTextlessRecords() {
        let records = [
            AXElementRecord(id: "0", role: "AXWindow", title: "Doc"),
            AXElementRecord(id: "0.0", role: "AXGroup"),
            AXElementRecord(id: "0.0.0", role: "AXStaticText", value: "Hello"),
            AXElementRecord(id: "0.0.1", role: "AXButton", title: "Save", value: "on"),
            AXElementRecord(id: "0.1", role: "AXImage")
        ]

        XCTAssertEqual(
            AXTextRenderer.render(records),
            """
            AXWindow "Doc"
                AXStaticText: Hello
                AXButton "Save": on
            """
        )
    }

    func testFallsBackToDescriptionWhenTitleMissing() {
        let record = AXElementRecord(id: "0", role: "AXButton", description: "close")
        XCTAssertEqual(AXTextRenderer.renderLine(record), "AXButton \"close\"")
    }

    func testWhitespaceOnlyContentCountsAsEmpty() {
        let record = AXElementRecord(id: "0", role: "AXGroup", title: "  ", value: "\n")
        XCTAssertNil(AXTextRenderer.renderLine(record))
    }
}

final class AXBoundsMapperTests: XCTestCase {
    /// Mirrors CoordinateMapperTests: scale 2.0, secondary-display-style nonzero origin.
    private let metadata = ScreenshotMetadata(
        capturedAtISO8601: "2026-07-06T00:00:00Z",
        displayID: 1,
        displayBoundsPoints: RectD(x: 100, y: 200, w: 500, h: 300),
        imageSizePixels: SizeD(w: 1000, h: 600),
        pointPixelScale: 2.0,
        imagePath: "/tmp/test.png"
    )

    func testMapsGlobalPointsToScreenshotPixels() {
        let pixels = AXBoundsMapper.boundsPixels(
            for: RectD(x: 200, y: 250, w: 50, h: 40),
            metadata: metadata
        )
        XCTAssertEqual(pixels, RectD(x: 200, y: 100, w: 100, h: 80))
    }

    func testFrameFillingWholeDisplayMaps() {
        let pixels = AXBoundsMapper.boundsPixels(
            for: RectD(x: 100, y: 200, w: 500, h: 300),
            metadata: metadata
        )
        XCTAssertEqual(pixels, RectD(x: 0, y: 0, w: 1000, h: 600))
    }

    func testFrameOutsideMetadataBoundsReturnsNil() {
        XCTAssertNil(AXBoundsMapper.boundsPixels(for: RectD(x: 700, y: 250, w: 10, h: 10), metadata: metadata))
        XCTAssertNil(AXBoundsMapper.boundsPixels(for: RectD(x: 0, y: 0, w: 10, h: 10), metadata: metadata))
    }

    func testFramePartiallyOutsideBoundsReturnsNil() {
        XCTAssertNil(AXBoundsMapper.boundsPixels(for: RectD(x: 550, y: 250, w: 100, h: 10), metadata: metadata))
    }

    func testNonPositiveScaleReturnsNil() {
        var broken = metadata
        broken.pointPixelScale = 0
        XCTAssertNil(AXBoundsMapper.boundsPixels(for: RectD(x: 200, y: 250, w: 10, h: 10), metadata: broken))
    }

    /// Window-scoped metadata: mirrors CoordinateMapper's `windowBoundsPoints ??
    /// displayBoundsPoints` rule, with real display bounds alongside the window rect.
    private var windowMetadata: ScreenshotMetadata {
        var windowScoped = metadata
        windowScoped.displayBoundsPoints = RectD(x: 0, y: 0, w: 2560, h: 1600)
        windowScoped.imageSizePixels = SizeD(w: 1600, h: 1200)
        windowScoped.windowID = 42
        windowScoped.windowBoundsPoints = RectD(x: 500, y: 300, w: 800, h: 600)
        return windowScoped
    }

    func testWindowMetadataMapsAgainstWindowBounds() {
        // Global frame (600, 350, 100, 50) inside the window at (500, 300):
        // pixels = ((600-500)*2, (350-300)*2, 100*2, 50*2).
        let pixels = AXBoundsMapper.boundsPixels(
            for: RectD(x: 600, y: 350, w: 100, h: 50),
            metadata: windowMetadata
        )
        XCTAssertEqual(pixels, RectD(x: 200, y: 100, w: 200, h: 100))
    }

    func testWindowMetadataRejectsFramesOutsideWindowEvenWhenOnDisplay() {
        // (100, 100) is well inside the display but outside the captured window,
        // so it has no representation in the window screenshot's pixel space.
        XCTAssertNil(
            AXBoundsMapper.boundsPixels(
                for: RectD(x: 100, y: 100, w: 10, h: 10),
                metadata: windowMetadata
            )
        )
    }
}

final class AXTreeUnavailableHeuristicTests: XCTestCase {
    func testOneNodeNaturalTraversalIsUnusable() {
        XCTAssertTrue(AXReader.indicatesUnusableTree(visitedCount: 1, truncated: false, maxDepth: 40))
        XCTAssertTrue(AXReader.indicatesUnusableTree(visitedCount: 0, truncated: false, maxDepth: 40))
    }

    func testTruncatedTraversalIsNotUnusable() {
        // --max-elements 1 halts after the root with truncated == true.
        XCTAssertFalse(AXReader.indicatesUnusableTree(visitedCount: 1, truncated: true, maxDepth: 40))
    }

    func testDepthLimitedSingleRootIsNotUnusable() {
        // --max-depth 1 on a single-window app visits only the root window.
        XCTAssertFalse(AXReader.indicatesUnusableTree(visitedCount: 1, truncated: false, maxDepth: 1))
    }

    func testMultiNodeTreeIsNotUnusable() {
        XCTAssertFalse(AXReader.indicatesUnusableTree(visitedCount: 5, truncated: false, maxDepth: 40))
    }
}

final class AXIDPathTests: XCTestCase {
    func testParsesDotJoinedChildIndexPaths() throws {
        XCTAssertEqual(try AXReader.parseIDPath("0"), [0])
        XCTAssertEqual(try AXReader.parseIDPath("0.3.2"), [0, 3, 2])
        XCTAssertEqual(try AXReader.parseIDPath(" 1.2 "), [1, 2])
    }

    func testRejectsMalformedIDPaths() {
        for malformed in ["", "  ", "a.b", "0..2", "0.", ".0", "-1", "1.-2", "1,2"] {
            XCTAssertThrowsError(try AXReader.parseIDPath(malformed), "expected '\(malformed)' to be rejected") { error in
                XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "invalid_arguments")
            }
        }
    }
}
