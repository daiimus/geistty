import XCTest
@testable import Geistty

// MARK: - TmuxLayout Tests

final class TmuxLayoutTests: XCTestCase {

    // MARK: - TmuxChecksum

    func testChecksumEmptyString() {
        let checksum = TmuxChecksum.calculate("")
        // Empty string should produce 0 checksum
        XCTAssertEqual(checksum.asString(), "0000")
    }

    func testChecksumProduces4CharHex() {
        let checksum = TmuxChecksum.calculate("80x24,0,0,42")
        let str = checksum.asString()
        XCTAssertEqual(str.count, 4, "Checksum should always be 4 hex characters")
    }

    func testChecksumDeterministic() {
        let input = "80x24,0,0,42"
        let a = TmuxChecksum.calculate(input)
        let b = TmuxChecksum.calculate(input)
        XCTAssertEqual(a, b)
    }

    func testChecksumDifferentInputs() {
        let a = TmuxChecksum.calculate("80x24,0,0,1")
        let b = TmuxChecksum.calculate("80x24,0,0,2")
        XCTAssertNotEqual(a, b, "Different inputs should produce different checksums")
    }

    func testChecksumZeroPadding() {
        // The checksum is always zero-padded to 4 chars
        let checksum = TmuxChecksum(value: 0x0A)
        XCTAssertEqual(checksum.asString(), "000a")
    }

    func testChecksumKnownValue() {
        // Verify against a known tmux layout string
        // Layout "80x24,0,0,42" should produce checksum "d962"
        let checksum = TmuxChecksum.calculate("80x24,0,0,42")
        XCTAssertEqual(checksum.asString(), "d962")
    }

    // MARK: - Parse Single Pane

    func testParseSinglePane() throws {
        let layout = try TmuxLayout.parse("80x24,0,0,42")
        XCTAssertEqual(layout.width, 80)
        XCTAssertEqual(layout.height, 24)
        XCTAssertEqual(layout.x, 0)
        XCTAssertEqual(layout.y, 0)
        XCTAssertEqual(layout.content, .pane(id: 42))
    }

    func testParseSinglePaneLargeDimensions() throws {
        let layout = try TmuxLayout.parse("200x50,10,5,0")
        XCTAssertEqual(layout.width, 200)
        XCTAssertEqual(layout.height, 50)
        XCTAssertEqual(layout.x, 10)
        XCTAssertEqual(layout.y, 5)
        XCTAssertEqual(layout.content, .pane(id: 0))
    }

    // MARK: - Parse Horizontal Split

    func testParseHorizontalSplit() throws {
        let layout = try TmuxLayout.parse("80x24,0,0{40x24,0,0,1,39x24,41,0,2}")
        XCTAssertEqual(layout.width, 80)
        XCTAssertEqual(layout.height, 24)
        XCTAssertTrue(layout.isSplit)
        XCTAssertFalse(layout.isPane)

        if case .horizontal(let children) = layout.content {
            XCTAssertEqual(children.count, 2)
            XCTAssertEqual(children[0].width, 40)
            XCTAssertEqual(children[0].content, .pane(id: 1))
            XCTAssertEqual(children[1].width, 39)
            XCTAssertEqual(children[1].x, 41)
            XCTAssertEqual(children[1].content, .pane(id: 2))
        } else {
            XCTFail("Expected horizontal split")
        }
    }

    // MARK: - Parse Vertical Split

    func testParseVerticalSplit() throws {
        let layout = try TmuxLayout.parse("80x24,0,0[80x12,0,0,1,80x11,0,13,2]")
        XCTAssertEqual(layout.width, 80)
        XCTAssertEqual(layout.height, 24)

        if case .vertical(let children) = layout.content {
            XCTAssertEqual(children.count, 2)
            XCTAssertEqual(children[0].height, 12)
            XCTAssertEqual(children[0].content, .pane(id: 1))
            XCTAssertEqual(children[1].height, 11)
            XCTAssertEqual(children[1].y, 13)
            XCTAssertEqual(children[1].content, .pane(id: 2))
        } else {
            XCTFail("Expected vertical split")
        }
    }

    // MARK: - Parse Nested Splits

    func testParseNestedSplits() throws {
        // Horizontal split where right child is a vertical split
        let layout = try TmuxLayout.parse("80x24,0,0{40x24,0,0,1,39x24,41,0[39x12,41,0,2,39x11,41,13,3]}")
        XCTAssertEqual(layout.width, 80)

        if case .horizontal(let children) = layout.content {
            XCTAssertEqual(children.count, 2)
            XCTAssertEqual(children[0].content, .pane(id: 1))

            if case .vertical(let nested) = children[1].content {
                XCTAssertEqual(nested.count, 2)
                XCTAssertEqual(nested[0].content, .pane(id: 2))
                XCTAssertEqual(nested[1].content, .pane(id: 3))
            } else {
                XCTFail("Expected nested vertical split")
            }
        } else {
            XCTFail("Expected horizontal split")
        }
    }

    // MARK: - Parse Three-Way Split

    func testParseThreeWayHorizontalSplit() throws {
        let layout = try TmuxLayout.parse("120x24,0,0{40x24,0,0,1,40x24,41,0,2,38x24,82,0,3}")

        if case .horizontal(let children) = layout.content {
            XCTAssertEqual(children.count, 3)
            XCTAssertEqual(children[0].content, .pane(id: 1))
            XCTAssertEqual(children[1].content, .pane(id: 2))
            XCTAssertEqual(children[2].content, .pane(id: 3))
        } else {
            XCTFail("Expected horizontal split with 3 children")
        }
    }

    // MARK: - ParseWithChecksum

    func testParseWithChecksumValid() throws {
        let layoutStr = "80x24,0,0,42"
        let checksum = TmuxChecksum.calculate(layoutStr).asString()
        let full = "\(checksum),\(layoutStr)"

        let layout = try TmuxLayout.parseWithChecksum(full)
        XCTAssertEqual(layout.content, .pane(id: 42))
    }

    func testParseWithChecksumMismatch() {
        // Use a wrong checksum
        let full = "0000,80x24,0,0,42"
        XCTAssertThrowsError(try TmuxLayout.parseWithChecksum(full)) { error in
            XCTAssertEqual(error as? TmuxLayout.ParseError, .checksumMismatch)
        }
    }

    func testParseWithChecksumTooShort() {
        XCTAssertThrowsError(try TmuxLayout.parseWithChecksum("abc")) { error in
            XCTAssertEqual(error as? TmuxLayout.ParseError, .syntaxError)
        }
    }

    func testParseWithChecksumNoComma() {
        XCTAssertThrowsError(try TmuxLayout.parseWithChecksum("abcd80x24")) { error in
            XCTAssertEqual(error as? TmuxLayout.ParseError, .syntaxError)
        }
    }

    // MARK: - Error Cases

    func testParseEmptyString() {
        XCTAssertThrowsError(try TmuxLayout.parse("")) { error in
            XCTAssertEqual(error as? TmuxLayout.ParseError, .syntaxError)
        }
    }

    func testParseMissingDimensions() {
        XCTAssertThrowsError(try TmuxLayout.parse("80,0,0,42")) { error in
            XCTAssertEqual(error as? TmuxLayout.ParseError, .syntaxError)
        }
    }

    func testParseTrailingCharacters() {
        XCTAssertThrowsError(try TmuxLayout.parse("80x24,0,0,42extra")) { error in
            XCTAssertEqual(error as? TmuxLayout.ParseError, .syntaxError)
        }
    }

    func testParseMissingPaneId() {
        // No pane ID after last comma — no delimiter to terminate
        XCTAssertThrowsError(try TmuxLayout.parse("80x24,0,0,")) { error in
            XCTAssertEqual(error as? TmuxLayout.ParseError, .syntaxError)
        }
    }

    func testParseUnclosedBracket() {
        XCTAssertThrowsError(try TmuxLayout.parse("80x24,0,0{40x24,0,0,1")) { error in
            XCTAssertEqual(error as? TmuxLayout.ParseError, .syntaxError)
        }
    }

    // MARK: - Convenience Properties

    func testPaneIdsSinglePane() throws {
        let layout = try TmuxLayout.parse("80x24,0,0,42")
        XCTAssertEqual(layout.paneIds, [42])
    }

    func testPaneIdsMultiplePanes() throws {
        let layout = try TmuxLayout.parse("80x24,0,0{40x24,0,0,1,39x24,41,0,2}")
        XCTAssertEqual(layout.paneIds, [1, 2])
    }

    func testPaneIdsNestedDepthFirst() throws {
        let layout = try TmuxLayout.parse("80x24,0,0{40x24,0,0,1,39x24,41,0[39x12,41,0,3,39x11,41,13,2]}")
        XCTAssertEqual(layout.paneIds, [1, 3, 2], "Pane IDs should be in depth-first order")
    }

    func testFindPaneHit() throws {
        let layout = try TmuxLayout.parse("80x24,0,0{40x24,0,0,1,39x24,41,0,2}")
        let found = layout.findPane(2)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.width, 39)
        XCTAssertEqual(found?.content, .pane(id: 2))
    }

    func testFindPaneMiss() throws {
        let layout = try TmuxLayout.parse("80x24,0,0{40x24,0,0,1,39x24,41,0,2}")
        XCTAssertNil(layout.findPane(99))
    }

    func testIsPaneLeaf() throws {
        let layout = try TmuxLayout.parse("80x24,0,0,42")
        XCTAssertTrue(layout.isPane)
        XCTAssertFalse(layout.isSplit)
    }

    func testIsSplitContainer() throws {
        let layout = try TmuxLayout.parse("80x24,0,0{40x24,0,0,1,39x24,41,0,2}")
        XCTAssertTrue(layout.isSplit)
        XCTAssertFalse(layout.isPane)
    }

    // MARK: - Equatable

    func testLayoutEquatable() throws {
        let a = try TmuxLayout.parse("80x24,0,0,42")
        let b = try TmuxLayout.parse("80x24,0,0,42")
        XCTAssertEqual(a, b)
    }

    func testLayoutNotEqual() throws {
        let a = try TmuxLayout.parse("80x24,0,0,1")
        let b = try TmuxLayout.parse("80x24,0,0,2")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Debug Description

    func testDebugDescriptionSinglePane() throws {
        let layout = try TmuxLayout.parse("80x24,0,0,42")
        let desc = layout.debugDescription
        XCTAssertTrue(desc.contains("Pane 42"), "Debug description should mention pane ID")
        XCTAssertTrue(desc.contains("80x24"), "Debug description should mention dimensions")
    }

    func testDebugDescriptionSplit() throws {
        let layout = try TmuxLayout.parse("80x24,0,0{40x24,0,0,1,39x24,41,0,2}")
        let desc = layout.debugDescription
        XCTAssertTrue(desc.contains("Horizontal"), "Debug description should mention split direction")
    }
}
