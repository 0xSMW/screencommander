import CoreGraphics
import XCTest
@testable import ScreenCommander

final class MouseControllerTests: XCTestCase {
    func testHumanLikeSingleClickDoesNotEmitExtraClick() throws {
        var eventTypes: [CGEventType] = []
        let controller = MouseController { event, _ in
            eventTypes.append(event.type)
        }

        try controller.click(
            at: CGPoint(x: 10, y: 20),
            button: .left,
            doubleClick: false,
            tripleClick: false,
            primeClick: false,
            humanLike: true,
            modifiers: [],
            destination: .global
        )

        XCTAssertEqual(eventTypes.filter { $0 == .leftMouseDown }.count, 1)
        XCTAssertEqual(eventTypes.filter { $0 == .leftMouseUp }.count, 1)
    }

    func testHumanLikeDoubleClickEmitsExactlyTwoClicks() throws {
        var eventTypes: [CGEventType] = []
        var clickStates: [Int64] = []
        let controller = MouseController { event, _ in
            eventTypes.append(event.type)
            if event.type == .leftMouseDown {
                clickStates.append(event.getIntegerValueField(.mouseEventClickState))
            }
        }

        try controller.click(
            at: CGPoint(x: 10, y: 20),
            button: .left,
            doubleClick: true,
            tripleClick: false,
            primeClick: false,
            humanLike: true,
            modifiers: [],
            destination: .global
        )

        XCTAssertEqual(eventTypes.filter { $0 == .leftMouseDown }.count, 2)
        XCTAssertEqual(eventTypes.filter { $0 == .leftMouseUp }.count, 2)
        XCTAssertEqual(clickStates, [1, 2])
    }
}
