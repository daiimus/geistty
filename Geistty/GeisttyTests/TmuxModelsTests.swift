import XCTest
@testable import Geistty

// MARK: - TmuxModels Tests

final class TmuxModelsTests: XCTestCase {

    // MARK: - TmuxId Validation

    func testValidSessionId() {
        XCTAssertTrue(TmuxId.isValidSessionId("$0"))
        XCTAssertTrue(TmuxId.isValidSessionId("$123"))
        XCTAssertTrue(TmuxId.isValidSessionId("$999999"))
    }

    func testInvalidSessionId() {
        XCTAssertFalse(TmuxId.isValidSessionId(""))
        XCTAssertFalse(TmuxId.isValidSessionId("$"))
        XCTAssertFalse(TmuxId.isValidSessionId("0"))
        XCTAssertFalse(TmuxId.isValidSessionId("@0"))
        XCTAssertFalse(TmuxId.isValidSessionId("%0"))
        XCTAssertFalse(TmuxId.isValidSessionId("$abc"))
        XCTAssertFalse(TmuxId.isValidSessionId("session"))
    }

    func testValidWindowId() {
        XCTAssertTrue(TmuxId.isValidWindowId("@0"))
        XCTAssertTrue(TmuxId.isValidWindowId("@42"))
        XCTAssertTrue(TmuxId.isValidWindowId("@100"))
    }

    func testInvalidWindowId() {
        XCTAssertFalse(TmuxId.isValidWindowId(""))
        XCTAssertFalse(TmuxId.isValidWindowId("@"))
        XCTAssertFalse(TmuxId.isValidWindowId("0"))
        XCTAssertFalse(TmuxId.isValidWindowId("$0"))
        XCTAssertFalse(TmuxId.isValidWindowId("%0"))
        XCTAssertFalse(TmuxId.isValidWindowId("@abc"))
    }

    func testValidPaneId() {
        XCTAssertTrue(TmuxId.isValidPaneId("%0"))
        XCTAssertTrue(TmuxId.isValidPaneId("%5"))
        XCTAssertTrue(TmuxId.isValidPaneId("%99"))
    }

    func testInvalidPaneId() {
        XCTAssertFalse(TmuxId.isValidPaneId(""))
        XCTAssertFalse(TmuxId.isValidPaneId("%"))
        XCTAssertFalse(TmuxId.isValidPaneId("0"))
        XCTAssertFalse(TmuxId.isValidPaneId("$0"))
        XCTAssertFalse(TmuxId.isValidPaneId("@0"))
        XCTAssertFalse(TmuxId.isValidPaneId("%abc"))
    }

    // MARK: - TmuxId Numeric Extraction

    func testNumericPaneId() {
        XCTAssertEqual(TmuxId.numericPaneId("%0"), 0)
        XCTAssertEqual(TmuxId.numericPaneId("%5"), 5)
        XCTAssertEqual(TmuxId.numericPaneId("%42"), 42)
        XCTAssertNil(TmuxId.numericPaneId("invalid"))
        XCTAssertNil(TmuxId.numericPaneId("%"))
        XCTAssertNil(TmuxId.numericPaneId(""))
    }

    func testNumericWindowId() {
        XCTAssertEqual(TmuxId.numericWindowId("@0"), 0)
        XCTAssertEqual(TmuxId.numericWindowId("@3"), 3)
        XCTAssertEqual(TmuxId.numericWindowId("@100"), 100)
        XCTAssertNil(TmuxId.numericWindowId("invalid"))
        XCTAssertNil(TmuxId.numericWindowId("@"))
    }

    func testNumericSessionId() {
        XCTAssertEqual(TmuxId.numericSessionId("$0"), 0)
        XCTAssertEqual(TmuxId.numericSessionId("$7"), 7)
        XCTAssertEqual(TmuxId.numericSessionId("$256"), 256)
        XCTAssertNil(TmuxId.numericSessionId("invalid"))
        XCTAssertNil(TmuxId.numericSessionId("$"))
    }

    func testPaneIdString() {
        XCTAssertEqual(TmuxId.paneIdString(0), "%0")
        XCTAssertEqual(TmuxId.paneIdString(5), "%5")
        XCTAssertEqual(TmuxId.paneIdString(42), "%42")
    }

    // MARK: - Model Initialization & Equatable

    func testSessionEquatable() {
        let a = TmuxSession(id: "$0", name: "main")
        let b = TmuxSession(id: "$0", name: "main")
        XCTAssertEqual(a, b)
    }

    func testSessionNotEqual() {
        let a = TmuxSession(id: "$0", name: "main")
        let b = TmuxSession(id: "$1", name: "work")
        XCTAssertNotEqual(a, b)
    }

    func testWindowEquatable() {
        let a = TmuxWindow(id: "@0", index: 0, name: "bash", sessionId: "$0")
        let b = TmuxWindow(id: "@0", index: 0, name: "bash", sessionId: "$0")
        XCTAssertEqual(a, b)
    }

    // MARK: - TmuxId Round-trip

    func testPaneIdRoundTrip() {
        for id in [0, 1, 5, 42, 999] {
            let str = TmuxId.paneIdString(id)
            XCTAssertEqual(TmuxId.numericPaneId(str), id, "Round-trip failed for pane ID \(id)")
        }
    }
    
    // MARK: - TmuxId Numeric Sort
    
    func testSortedNumericallyBasic() {
        // Lexicographic sort: ["%10", "%11", "%9"]
        // Numeric sort: ["%9", "%10", "%11"]
        let ids = ["%9", "%10", "%11"]
        let sorted = TmuxId.sortedNumerically(ids)
        XCTAssertEqual(sorted, ["%9", "%10", "%11"])
    }
    
    func testSortedNumericallyAlreadySorted() {
        let ids = ["%0", "%1", "%2"]
        let sorted = TmuxId.sortedNumerically(ids)
        XCTAssertEqual(sorted, ["%0", "%1", "%2"])
    }
    
    func testSortedNumericallyReversed() {
        let ids = ["%100", "%20", "%3"]
        let sorted = TmuxId.sortedNumerically(ids)
        XCTAssertEqual(sorted, ["%3", "%20", "%100"])
    }
    
    func testSortedNumericallyFromSet() {
        // Sets have no guaranteed order — numeric sort should still work
        let ids: Set<String> = ["%9", "%10", "%11"]
        let sorted = TmuxId.sortedNumerically(ids)
        XCTAssertEqual(sorted, ["%9", "%10", "%11"])
    }
    
    func testSortedNumericallyWindowIds() {
        // Also works with @ prefix (window IDs)
        let ids = ["@9", "@10", "@2"]
        let sorted = TmuxId.sortedNumerically(ids)
        XCTAssertEqual(sorted, ["@2", "@9", "@10"])
    }
    
    func testSortedNumericallyEmpty() {
        let sorted = TmuxId.sortedNumerically([String]())
        XCTAssertEqual(sorted, [])
    }
    
    func testSortedNumericalySingle() {
        let sorted = TmuxId.sortedNumerically(["%42"])
        XCTAssertEqual(sorted, ["%42"])
    }
}
