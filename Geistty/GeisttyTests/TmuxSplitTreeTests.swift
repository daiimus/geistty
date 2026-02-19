import XCTest
@testable import Geistty

// MARK: - TmuxSplitTree Tests

final class TmuxSplitTreeTests: XCTestCase {

    // MARK: - Helpers

    /// Build a simple horizontal split tree: [pane1 | pane2]
    private func makeHorizontalSplit(
        left: Int = 1, right: Int = 2,
        leftCols: Int = 40, rightCols: Int = 39,
        rows: Int = 24
    ) -> TmuxSplitTree {
        let totalCols = Double(leftCols + rightCols)
        let ratio = totalCols > 0 ? Double(leftCols) / totalCols : 0.5
        let root: TmuxSplitTree.Node = .split(.init(
            direction: .horizontal,
            ratio: ratio,
            left: .leaf(paneId: left, cols: leftCols, rows: rows),
            right: .leaf(paneId: right, cols: rightCols, rows: rows)
        ))
        return TmuxSplitTree(root: root)
    }

    /// Build a vertical split tree with nested right child
    private func makeNestedSplit() -> TmuxSplitTree {
        // [pane1 | [pane2 / pane3]]
        let rightSplit: TmuxSplitTree.Node = .split(.init(
            direction: .vertical,
            ratio: 0.5,
            left: .leaf(paneId: 2, cols: 39, rows: 12),
            right: .leaf(paneId: 3, cols: 39, rows: 11)
        ))
        let root: TmuxSplitTree.Node = .split(.init(
            direction: .horizontal,
            ratio: 0.506,
            left: .leaf(paneId: 1, cols: 40, rows: 24),
            right: rightSplit
        ))
        return TmuxSplitTree(root: root)
    }

    // MARK: - Initialization

    func testEmptyTree() {
        let tree = TmuxSplitTree()
        XCTAssertTrue(tree.isEmpty)
        XCTAssertFalse(tree.isSplit)
        XCTAssertEqual(tree.paneIds, [])
        XCTAssertNil(tree.root)
        XCTAssertNil(tree.zoomed)
    }

    func testSinglePaneTree() {
        let tree = TmuxSplitTree(paneId: 42, cols: 80, rows: 24)
        XCTAssertFalse(tree.isEmpty)
        XCTAssertFalse(tree.isSplit)
        XCTAssertEqual(tree.paneIds, [42])
    }

    func testSinglePaneDefaultDimensions() {
        let tree = TmuxSplitTree(paneId: 0)
        let info = tree.paneInfo(for: 0)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.cols, 80)
        XCTAssertEqual(info?.rows, 24)
    }

    // MARK: - From TmuxLayout (Factory)

    func testFromLayoutSinglePane() throws {
        let layout = try TmuxLayout.parse("80x24,0,0,42")
        let tree = TmuxSplitTree.from(layout: layout)
        XCTAssertFalse(tree.isEmpty)
        XCTAssertFalse(tree.isSplit)
        XCTAssertEqual(tree.paneIds, [42])

        let info = tree.paneInfo(for: 42)
        XCTAssertEqual(info?.cols, 80)
        XCTAssertEqual(info?.rows, 24)
    }

    func testFromLayoutHorizontalSplit() throws {
        let layout = try TmuxLayout.parse("80x24,0,0{40x24,0,0,1,39x24,41,0,2}")
        let tree = TmuxSplitTree.from(layout: layout)
        XCTAssertTrue(tree.isSplit)
        XCTAssertEqual(tree.paneIds, [1, 2])
    }

    func testFromLayoutVerticalSplit() throws {
        let layout = try TmuxLayout.parse("80x24,0,0[80x12,0,0,1,80x11,0,13,2]")
        let tree = TmuxSplitTree.from(layout: layout)
        XCTAssertTrue(tree.isSplit)
        XCTAssertEqual(tree.paneIds, [1, 2])
    }

    func testFromLayoutNestedSplit() throws {
        let layout = try TmuxLayout.parse("80x24,0,0{40x24,0,0,1,39x24,41,0[39x12,41,0,2,39x11,41,13,3]}")
        let tree = TmuxSplitTree.from(layout: layout)
        XCTAssertTrue(tree.isSplit)
        XCTAssertEqual(tree.paneIds, [1, 2, 3])
    }

    func testFromLayoutThreeWaySplitBecomesBinaryTree() throws {
        // N-way split should become left-heavy binary tree
        let layout = try TmuxLayout.parse("120x24,0,0{40x24,0,0,1,40x24,41,0,2,38x24,82,0,3}")
        let tree = TmuxSplitTree.from(layout: layout)
        XCTAssertEqual(tree.paneIds, [1, 2, 3])

        // Verify left-heavy structure: root splits into pane1 and (pane2 + pane3)
        if case .split(let split) = tree.root {
            // Left child should be pane 1
            XCTAssertEqual(split.left.paneId, 1)
            // Right child should be a split containing panes 2 and 3
            if case .split(let rightSplit) = split.right {
                XCTAssertEqual(rightSplit.left.paneId, 2)
                XCTAssertEqual(rightSplit.right.paneId, 3)
            } else {
                XCTFail("Right child should be a split")
            }
        } else {
            XCTFail("Root should be a split")
        }
    }

    func testFromLayoutPreservesDimensions() throws {
        let layout = try TmuxLayout.parse("80x24,0,0{40x24,0,0,1,39x24,41,0,2}")
        let tree = TmuxSplitTree.from(layout: layout)

        let info1 = tree.paneInfo(for: 1)
        XCTAssertEqual(info1?.cols, 40)
        XCTAssertEqual(info1?.rows, 24)

        let info2 = tree.paneInfo(for: 2)
        XCTAssertEqual(info2?.cols, 39)
        XCTAssertEqual(info2?.rows, 24)
    }

    // MARK: - Queries: contains

    func testContainsExistingPane() {
        let tree = makeHorizontalSplit()
        XCTAssertTrue(tree.contains(paneId: 1))
        XCTAssertTrue(tree.contains(paneId: 2))
    }

    func testContainsNonExistentPane() {
        let tree = makeHorizontalSplit()
        XCTAssertFalse(tree.contains(paneId: 99))
    }

    func testContainsEmptyTree() {
        let tree = TmuxSplitTree()
        XCTAssertFalse(tree.contains(paneId: 1))
    }

    // MARK: - Queries: find

    func testFindExistingPane() {
        let tree = makeHorizontalSplit()
        let node = tree.find(paneId: 2)
        XCTAssertNotNil(node)
        XCTAssertEqual(node?.paneId, 2)
    }

    func testFindNonExistentPane() {
        let tree = makeHorizontalSplit()
        XCTAssertNil(tree.find(paneId: 99))
    }

    func testFindEmptyTree() {
        let tree = TmuxSplitTree()
        XCTAssertNil(tree.find(paneId: 1))
    }

    // MARK: - Queries: path

    func testPathToRootLeaf() {
        let tree = TmuxSplitTree(paneId: 42)
        let path = tree.path(to: 42)
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.isEmpty, "Path to root leaf should be empty")
    }

    func testPathToLeftChild() {
        let tree = makeHorizontalSplit()
        let path = tree.path(to: 1)
        XCTAssertNotNil(path)
        XCTAssertEqual(path?.components, [.left])
    }

    func testPathToRightChild() {
        let tree = makeHorizontalSplit()
        let path = tree.path(to: 2)
        XCTAssertNotNil(path)
        XCTAssertEqual(path?.components, [.right])
    }

    func testPathToNestedPane() {
        let tree = makeNestedSplit()
        let path = tree.path(to: 3)
        XCTAssertNotNil(path)
        XCTAssertEqual(path?.components, [.right, .right])
    }

    func testPathToNonExistentPane() {
        let tree = makeHorizontalSplit()
        XCTAssertNil(tree.path(to: 99))
    }

    func testPathEmptyTree() {
        let tree = TmuxSplitTree()
        XCTAssertNil(tree.path(to: 1))
    }

    // MARK: - Queries: paneInfo

    func testPaneInfoExisting() {
        let tree = makeHorizontalSplit(left: 1, right: 2, leftCols: 40, rightCols: 39, rows: 24)
        let info = tree.paneInfo(for: 1)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.paneId, 1)
        XCTAssertEqual(info?.cols, 40)
        XCTAssertEqual(info?.rows, 24)
    }

    func testPaneInfoNonExistent() {
        let tree = makeHorizontalSplit()
        XCTAssertNil(tree.paneInfo(for: 99))
    }

    func testPaneInfoEmptyTree() {
        let tree = TmuxSplitTree()
        XCTAssertNil(tree.paneInfo(for: 1))
    }

    // MARK: - Queries: allPaneInfos

    func testAllPaneInfos() {
        let tree = makeNestedSplit()
        let infos = tree.allPaneInfos
        XCTAssertEqual(infos.count, 3)
        XCTAssertEqual(infos.map(\.paneId), [1, 2, 3])
    }

    func testAllPaneInfosEmptyTree() {
        let tree = TmuxSplitTree()
        XCTAssertEqual(tree.allPaneInfos, [])
    }

    // MARK: - Node Properties

    func testNodePaneIdLeaf() {
        let node: TmuxSplitTree.Node = .leaf(paneId: 42, cols: 80, rows: 24)
        XCTAssertEqual(node.paneId, 42)
    }

    func testNodePaneIdSplit() {
        let node: TmuxSplitTree.Node = .split(.init(
            direction: .horizontal, ratio: 0.5,
            left: .leaf(paneId: 1, cols: 40, rows: 24),
            right: .leaf(paneId: 2, cols: 39, rows: 24)
        ))
        XCTAssertNil(node.paneId, "Split nodes should not have a pane ID")
    }

    func testNodeDimensions() {
        let node: TmuxSplitTree.Node = .leaf(paneId: 1, cols: 120, rows: 40)
        let dims = node.dimensions
        XCTAssertEqual(dims?.cols, 120)
        XCTAssertEqual(dims?.rows, 40)
    }

    func testNodeIsPane() {
        let leaf: TmuxSplitTree.Node = .leaf(paneId: 5, cols: 80, rows: 24)
        XCTAssertTrue(leaf.isPane(5))
        XCTAssertFalse(leaf.isPane(6))
    }

    func testNodeLeftmostPaneId() {
        let tree = makeNestedSplit()
        if case .split(let split) = tree.root {
            XCTAssertEqual(split.right.leftmostPaneId, 2)
        }
    }

    func testNodeRightmostPaneId() {
        let tree = makeNestedSplit()
        if case .split(let split) = tree.root {
            XCTAssertEqual(split.right.rightmostPaneId, 3)
        }
    }

    func testNodeLeafCount() {
        let tree = makeNestedSplit()
        if let root = tree.root {
            XCTAssertEqual(root.leafCount, 3)
        }
    }

    // MARK: - Modifications: toggleZoom

    func testToggleZoomOn() {
        let tree = makeHorizontalSplit()
        let zoomed = tree.toggleZoom(paneId: 1)
        XCTAssertNotNil(zoomed.zoomed)
        XCTAssertEqual(zoomed.zoomed?.paneId, 1)
    }

    func testToggleZoomOff() {
        let tree = makeHorizontalSplit()
        let zoomed = tree.toggleZoom(paneId: 1)
        let unzoomed = zoomed.toggleZoom(paneId: 1)
        XCTAssertNil(unzoomed.zoomed)
    }

    func testToggleZoomSwitchPane() {
        let tree = makeHorizontalSplit()
        let zoomed1 = tree.toggleZoom(paneId: 1)
        let zoomed2 = zoomed1.toggleZoom(paneId: 2)
        XCTAssertEqual(zoomed2.zoomed?.paneId, 2)
    }

    func testToggleZoomNonExistentPane() {
        let tree = makeHorizontalSplit()
        let result = tree.toggleZoom(paneId: 99)
        XCTAssertNil(result.zoomed, "Zooming non-existent pane should be no-op")
    }

    func testToggleZoomEmptyTree() {
        let tree = TmuxSplitTree()
        let result = tree.toggleZoom(paneId: 1)
        XCTAssertNil(result.zoomed)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Modifications: clearZoom

    func testClearZoom() {
        let tree = makeHorizontalSplit().toggleZoom(paneId: 1)
        XCTAssertNotNil(tree.zoomed)
        let cleared = tree.clearZoom()
        XCTAssertNil(cleared.zoomed)
        // Root should be preserved
        XCTAssertEqual(cleared.paneIds, [1, 2])
    }

    // MARK: - Modifications: equalize

    func testEqualizeRatios() {
        // Create tree with unequal ratio
        let root: TmuxSplitTree.Node = .split(.init(
            direction: .horizontal,
            ratio: 0.7,
            left: .leaf(paneId: 1, cols: 56, rows: 24),
            right: .leaf(paneId: 2, cols: 23, rows: 24)
        ))
        let tree = TmuxSplitTree(root: root)
        let equalized = tree.equalize()

        if case .split(let split) = equalized.root {
            XCTAssertEqual(split.ratio, 0.5, accuracy: 0.001)
        } else {
            XCTFail("Root should still be a split")
        }
    }

    func testEqualizeNestedRatios() {
        let tree = makeNestedSplit()
        let equalized = tree.equalize()

        // Check root ratio
        if case .split(let rootSplit) = equalized.root {
            XCTAssertEqual(rootSplit.ratio, 0.5, accuracy: 0.001)

            // Check nested ratio
            if case .split(let nestedSplit) = rootSplit.right {
                XCTAssertEqual(nestedSplit.ratio, 0.5, accuracy: 0.001)
            }
        }
    }

    func testEqualizeEmptyTree() {
        let tree = TmuxSplitTree()
        let equalized = tree.equalize()
        XCTAssertTrue(equalized.isEmpty)
    }

    func testEqualizeSinglePane() {
        let tree = TmuxSplitTree(paneId: 1)
        let equalized = tree.equalize()
        XCTAssertEqual(equalized.paneIds, [1])
    }

    // MARK: - Modifications: updateRatio

    func testUpdateRatio() {
        let tree = makeHorizontalSplit()
        let updated = tree.updateRatio(forPaneId: 1, ratio: 0.3)

        if case .split(let split) = updated.root {
            XCTAssertEqual(split.ratio, 0.3, accuracy: 0.001)
        } else {
            XCTFail("Root should still be a split")
        }
    }

    func testUpdateRatioNested() {
        let tree = makeNestedSplit()
        // Update the inner split (left child of inner split is pane 2)
        let updated = tree.updateRatio(forPaneId: 2, ratio: 0.7)

        if case .split(let rootSplit) = updated.root {
            if case .split(let innerSplit) = rootSplit.right {
                XCTAssertEqual(innerSplit.ratio, 0.7, accuracy: 0.001)
            } else {
                XCTFail("Right child should be a split")
            }
        }
    }

    // MARK: - Modifications: updatingDimensions

    func testUpdatingDimensions() {
        let tree = makeHorizontalSplit()
        let updated = tree.updatingDimensions(paneId: 1, cols: 60, rows: 30)

        let info = updated.paneInfo(for: 1)
        XCTAssertEqual(info?.cols, 60)
        XCTAssertEqual(info?.rows, 30)

        // Other pane should be unchanged
        let info2 = updated.paneInfo(for: 2)
        XCTAssertEqual(info2?.cols, 39)
        XCTAssertEqual(info2?.rows, 24)
    }

    func testUpdatingDimensionsNonExistentPane() {
        let tree = makeHorizontalSplit()
        let updated = tree.updatingDimensions(paneId: 99, cols: 100, rows: 50)
        // Should be no-op
        XCTAssertEqual(updated.paneIds, tree.paneIds)
        XCTAssertEqual(updated.paneInfo(for: 1)?.cols, 40)
    }

    func testUpdatingDimensionsUpdatesZoomedNode() {
        let tree = makeHorizontalSplit().toggleZoom(paneId: 1)
        let updated = tree.updatingDimensions(paneId: 1, cols: 100, rows: 50)

        // Zoomed node should also be updated
        XCTAssertEqual(updated.zoomed?.paneId, 1)
        if case .leaf(let info) = updated.zoomed {
            XCTAssertEqual(info.cols, 100)
            XCTAssertEqual(info.rows, 50)
        } else {
            XCTFail("Zoomed node should be a leaf")
        }
    }

    // MARK: - Codable Round-trip

    func testCodableRoundTripSinglePane() throws {
        let tree = TmuxSplitTree(paneId: 42, cols: 80, rows: 24)
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(TmuxSplitTree.self, from: data)
        XCTAssertEqual(tree, decoded)
    }

    func testCodableRoundTripSplit() throws {
        let tree = makeHorizontalSplit()
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(TmuxSplitTree.self, from: data)
        XCTAssertEqual(tree, decoded)
    }

    func testCodableRoundTripNested() throws {
        let tree = makeNestedSplit()
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(TmuxSplitTree.self, from: data)
        XCTAssertEqual(tree, decoded)
    }

    func testCodableRoundTripWithZoom() throws {
        let tree = makeHorizontalSplit().toggleZoom(paneId: 1)
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(TmuxSplitTree.self, from: data)

        XCTAssertEqual(decoded.zoomed?.paneId, 1)
        XCTAssertEqual(decoded.paneIds, [1, 2])
    }

    func testCodableRoundTripEmpty() throws {
        let tree = TmuxSplitTree()
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(TmuxSplitTree.self, from: data)
        XCTAssertTrue(decoded.isEmpty)
    }

    func testCodableVersionMismatch() throws {
        // Encode a tree, then tamper with the version
        let tree = TmuxSplitTree(paneId: 1)
        var json = try JSONEncoder().encode(tree)
        // Modify version field
        var dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        dict["version"] = 999
        json = try JSONSerialization.data(withJSONObject: dict)

        XCTAssertThrowsError(try JSONDecoder().decode(TmuxSplitTree.self, from: json))
    }

    // MARK: - PaneInfo

    func testPaneInfoSize() {
        let info = TmuxSplitTree.PaneInfo(paneId: 1, cols: 120, rows: 40)
        XCTAssertEqual(info.size.cols, 120)
        XCTAssertEqual(info.size.rows, 40)
    }

    func testPaneInfoDefaultDimensions() {
        let info = TmuxSplitTree.PaneInfo(paneId: 1)
        XCTAssertEqual(info.cols, 80)
        XCTAssertEqual(info.rows, 24)
    }

    func testPaneInfoEquatable() {
        let a = TmuxSplitTree.PaneInfo(paneId: 1, cols: 80, rows: 24)
        let b = TmuxSplitTree.PaneInfo(paneId: 1, cols: 80, rows: 24)
        XCTAssertEqual(a, b)
    }

    // MARK: - Path

    func testPathAppending() {
        let path = TmuxSplitTree.Path()
        let extended = path.appending(.left).appending(.right)
        XCTAssertEqual(extended.components, [.left, .right])
    }

    func testPathIsEmpty() {
        XCTAssertTrue(TmuxSplitTree.Path().isEmpty)
        XCTAssertFalse(TmuxSplitTree.Path([.left]).isEmpty)
    }

    // MARK: - Debug Description

    func testDebugDescriptionEmpty() {
        let tree = TmuxSplitTree()
        XCTAssertEqual(tree.debugDescription, "TmuxSplitTree(empty)")
    }

    func testDebugDescriptionSinglePane() {
        let tree = TmuxSplitTree(paneId: 42, cols: 80, rows: 24)
        let desc = tree.debugDescription
        XCTAssertTrue(desc.contains("Pane %42"))
        XCTAssertTrue(desc.contains("80x24"))
    }

    func testDebugDescriptionSplit() {
        let tree = makeHorizontalSplit()
        let desc = tree.debugDescription
        XCTAssertTrue(desc.contains("Split(H"))
        XCTAssertTrue(desc.contains("Pane %1"))
        XCTAssertTrue(desc.contains("Pane %2"))
    }

    func testDebugDescriptionZoomed() {
        let tree = TmuxSplitTree(paneId: 42, cols: 80, rows: 24)
        let zoomed = tree.toggleZoom(paneId: 42)
        let desc = zoomed.debugDescription
        XCTAssertTrue(desc.contains("[ZOOMED]"))
    }

    // MARK: - Ratio Calculation: Divider-Aware (Bug 1)

    /// tmux horizontal split: parent=80, left=40, right=39, divider=1.
    /// The ratio should be child0.width / parent.width = 40/80 = 0.5,
    /// NOT child0.width / (child0.width + child1.width) = 40/79 = 0.5063.
    func testFromLayoutHorizontalSplitRatioAccountsForDivider() throws {
        // Layout: 80x24,0,0{40x24,0,0,1,39x24,41,0,2}
        // Parent width = 80, left = 40, right = 39, divider = 1 (40 + 1 + 39 = 80)
        let layout = try TmuxLayout.parse("80x24,0,0{40x24,0,0,1,39x24,41,0,2}")
        let tree = TmuxSplitTree.from(layout: layout)

        guard case .split(let split) = tree.root else {
            XCTFail("Root should be a split")
            return
        }

        // Ratio should use parent width (80) as denominator
        // Expected: 40/80 = 0.5
        XCTAssertEqual(split.ratio, 0.5, accuracy: 0.001,
                       "Ratio should be child.width / parent.width = 40/80 = 0.5")
    }

    /// tmux vertical split: parent height=24, top=12, bottom=11, divider=1.
    func testFromLayoutVerticalSplitRatioAccountsForDivider() throws {
        // Layout: 80x24,0,0[80x12,0,0,1,80x11,0,13,2]
        // Parent height = 24, top = 12, bottom = 11, divider = 1 (12 + 1 + 11 = 24)
        let layout = try TmuxLayout.parse("80x24,0,0[80x12,0,0,1,80x11,0,13,2]")
        let tree = TmuxSplitTree.from(layout: layout)

        guard case .split(let split) = tree.root else {
            XCTFail("Root should be a split")
            return
        }

        // Expected: 12/24 = 0.5
        XCTAssertEqual(split.ratio, 0.5, accuracy: 0.001,
                       "Ratio should be child.height / parent.height = 12/24 = 0.5")
    }

    /// Unequal horizontal split: parent=80, left=26, right=53, divider=1.
    func testFromLayoutUnequalHorizontalSplitRatio() throws {
        // Layout: 80x24,0,0{26x24,0,0,1,53x24,27,0,2}
        // 26 + 1 + 53 = 80
        let layout = try TmuxLayout.parse("80x24,0,0{26x24,0,0,1,53x24,27,0,2}")
        let tree = TmuxSplitTree.from(layout: layout)

        guard case .split(let split) = tree.root else {
            XCTFail("Root should be a split")
            return
        }

        // Expected: 26/80 = 0.325
        XCTAssertEqual(split.ratio, 0.325, accuracy: 0.001,
                       "Ratio should be 26/80 = 0.325")
    }

    // MARK: - Ratio Calculation: N-ary Splits (Bug 6)

    /// 3-way horizontal split: parent=120, children 40+40+38, two dividers.
    /// First binary split: child0=40 vs rest(40+1+38=79), parent=120.
    /// Inner binary split: child1=40 vs child2=38, inner_width=79.
    func testFromLayoutThreeWaySplitRatioAccountsForDividers() throws {
        // Layout: 120x24,0,0{40x24,0,0,1,40x24,41,0,2,38x24,82,0,3}
        // Parent width = 120, children: 40, 40, 38
        // 40 + 1 + 40 + 1 + 38 = 120
        let layout = try TmuxLayout.parse("120x24,0,0{40x24,0,0,1,40x24,41,0,2,38x24,82,0,3}")
        let tree = TmuxSplitTree.from(layout: layout)

        guard case .split(let outerSplit) = tree.root else {
            XCTFail("Root should be a split")
            return
        }

        // Outer split: child0=40 out of parent=120
        // Expected outer ratio: 40/120 = 0.333
        XCTAssertEqual(outerSplit.ratio, 40.0 / 120.0, accuracy: 0.001,
                       "Outer ratio should be 40/120")

        // Inner split: child1=40 out of inner container width.
        // Inner container = 120 - 40 - 1 = 79 (rest of parent minus child0 minus 1 divider)
        // Inner ratio = 40/79 = 0.5063
        guard case .split(let innerSplit) = outerSplit.right else {
            XCTFail("Right child should be a split")
            return
        }

        XCTAssertEqual(innerSplit.ratio, 40.0 / 79.0, accuracy: 0.001,
                       "Inner ratio should be 40/79")
    }

    /// 4-way vertical split to stress-test N-ary divider accounting.
    func testFromLayoutFourWayVerticalSplitRatios() throws {
        // 4 panes stacked vertically:
        // Parent: 80x100
        // Children: 24, 24, 24, 25 (with 3 dividers: 24+1+24+1+24+1+25 = 100)
        let layout = try TmuxLayout.parse("80x100,0,0[80x24,0,0,1,80x24,0,25,2,80x24,0,50,3,80x25,0,75,4]")
        let tree = TmuxSplitTree.from(layout: layout)

        guard case .split(let s1) = tree.root else {
            XCTFail("Root should be a split"); return
        }

        // Outer: child0=24 out of parent=100
        XCTAssertEqual(s1.ratio, 24.0 / 100.0, accuracy: 0.001,
                       "First split: 24/100")

        guard case .split(let s2) = s1.right else {
            XCTFail("Expected nested split"); return
        }

        // Second level: child1=24 out of (100 - 24 - 1) = 75
        XCTAssertEqual(s2.ratio, 24.0 / 75.0, accuracy: 0.001,
                       "Second split: 24/75")

        guard case .split(let s3) = s2.right else {
            XCTFail("Expected nested split"); return
        }

        // Third level: child2=24 out of (75 - 24 - 1) = 50
        XCTAssertEqual(s3.ratio, 24.0 / 50.0, accuracy: 0.001,
                       "Third split: 24/50")
    }
}
