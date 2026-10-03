import XCTest
@testable import ScreenCommander

final class AXPartialScrollTests: XCTestCase {
    private enum PageFailure: Error, Equatable {
        case refused
    }

    func testFirstPageFailureRemainsEligibleForFallback() {
        var attempts = 0
        XCTAssertThrowsError(try AXActions.performPages(count: 4) {
            attempts += 1
            throw PageFailure.refused
        }) { error in
            XCTAssertEqual(error as? PageFailure, .refused)
            XCTAssertFalse(error is AXPartialScrollError)
        }
        XCTAssertEqual(attempts, 1)
    }

    func testLaterFailurePreservesCompletedPagesAndStopsSequence() {
        for completedPages in 1...3 {
            var attempts = 0
            XCTAssertThrowsError(try AXActions.performPages(count: 4) {
                attempts += 1
                if attempts == completedPages + 1 { throw PageFailure.refused }
            }) { error in
                guard let partial = error as? AXPartialScrollError else {
                    return XCTFail("Expected a partial scroll failure, got \(error)")
                }
                XCTAssertEqual(partial.completedPages, completedPages)
                XCTAssertEqual(partial.underlyingError as? PageFailure, .refused)
            }
            XCTAssertEqual(attempts, completedPages + 1)
        }
    }

    func testSuccessfulSequencePerformsRequestedPagesExactlyOnce() throws {
        var attempts = 0
        try AXActions.performPages(count: 4) { attempts += 1 }
        XCTAssertEqual(attempts, 4)
    }
}
