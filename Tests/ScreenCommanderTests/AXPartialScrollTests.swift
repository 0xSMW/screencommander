import ApplicationServices
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

    func testUncertainFirstMutationCannotBeRetriedForActionsButtonsOrValues() {
        for operation in ["AXScrollDownByPage", "AXIncrementPage", "AXValue"] {
            for status in [AXError.cannotComplete, .failure, .invalidUIElement] {
                var applied = 0
                XCTAssertThrowsError(try AXActions.performPages(count: 3) {
                    applied += 1 // The app can mutate before returning an uncertain reply.
                    try AXActions.requireConfirmedScroll(status, operation: operation)
                }) { error in
                    XCTAssertTrue(error is AXUnconfirmedScrollError, "\(operation): \(error)")
                }
                XCTAssertEqual(applied, 1)
            }
        }
    }

    func testConfirmedAXRefusalRemainsEligibleForFallback() {
        for status in [AXError.actionUnsupported, .attributeUnsupported, .notImplemented] {
            XCTAssertThrowsError(try AXActions.requireConfirmedScroll(status, operation: "scroll")) { error in
                XCTAssertTrue(error is ScreenCommanderError)
                XCTAssertFalse(error is AXUnconfirmedScrollError)
            }
        }
    }

    func testUncertainLaterPagePreservesProgressAndUnderlyingPublicError() {
        var attempts = 0
        XCTAssertThrowsError(try AXActions.performPages(count: 3) {
            attempts += 1
            try AXActions.requireConfirmedScroll(attempts == 1 ? .success : .cannotComplete, operation: "scroll")
        }) { error in
            let partial = error as? AXPartialScrollError
            XCTAssertEqual(partial?.completedPages, 1)
            XCTAssertTrue(partial?.underlyingError is ScreenCommanderError)
        }
        XCTAssertEqual(attempts, 2)
    }

    func testSuccessfulSequencePerformsRequestedPagesExactlyOnce() throws {
        var attempts = 0
        try AXActions.performPages(count: 4) { attempts += 1 }
        XCTAssertEqual(attempts, 4)
    }
}
