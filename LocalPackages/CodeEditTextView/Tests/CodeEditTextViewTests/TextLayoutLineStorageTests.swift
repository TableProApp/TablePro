import XCTest
@testable import CodeEditTextView

fileprivate extension CGFloat {
    func approxEqual(_ value: CGFloat) -> Bool {
        return abs(self - value) < 0.05
    }
}

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

final class TextLayoutLineStorageTests: XCTestCase { // swiftlint:disable:this type_body_length

    /// Creates a balanced height=3 tree useful for testing and debugging.
    /// - Returns: A new tree.
    fileprivate func createBalancedTree() -> TextLineStorage<TextLine> {
        let tree = TextLineStorage<TextLine>()
        var data = [TextLineStorage<TextLine>.BuildItem]()
        for idx in 0..<15 {
            data.append(.init(data: TextLine(), length: idx + 1, height: 1.0))
        }
        tree.build(from: data, estimatedLineHeight: 1.0)
        return tree
    }

    struct ChildData {
        let length: Int
        let count: Int
        let height: CGFloat
        let maxWidth: CGFloat
    }

    /// Recursively checks that the given tree has the correct metadata everywhere.
    /// - Parameter tree: The tree to check.
    fileprivate func assertTreeMetadataCorrect<T: Identifiable>(_ tree: TextLineStorage<T>) throws {
        func checkChildren(_ node: TextLineStorage<T>.Node<T>?) -> ChildData {
            guard let node else { return ChildData(length: 0, count: 0, height: 0.0, maxWidth: 0.0) }
            let leftSubtreeData = checkChildren(node.left)
            let rightSubtreeData = checkChildren(node.right)

            XCTAssert(leftSubtreeData.length == node.leftSubtreeOffset, "Left subtree length incorrect")
            XCTAssert(leftSubtreeData.count == node.leftSubtreeCount, "Left subtree node count incorrect")
            XCTAssert(leftSubtreeData.height.approxEqual(node.leftSubtreeHeight), "Left subtree height incorrect")

            let subtreeWidth = max(node.width, leftSubtreeData.maxWidth, rightSubtreeData.maxWidth)
            XCTAssertEqual(node.subtreeWidth, subtreeWidth, "Subtree width incorrect")

            return ChildData(
                length: node.length + leftSubtreeData.length + rightSubtreeData.length,
                count: 1 + leftSubtreeData.count + rightSubtreeData.count,
                height: node.height + leftSubtreeData.height + rightSubtreeData.height,
                maxWidth: subtreeWidth
            )
        }

        let rootData = checkChildren(tree.root)

        XCTAssert(rootData.count == tree.count, "Node count incorrect")
        XCTAssert(rootData.length == tree.length, "Length incorrect")
        XCTAssert(rootData.height.approxEqual(tree.height), "Height incorrect")
        XCTAssertEqual(rootData.maxWidth, tree.maxWidth, "Max width incorrect")

        var lastIdx = -1
        for line in tree {
            XCTAssert(lastIdx == line.index - 1, "Incorrect index found")
            lastIdx = line.index
        }
    }

    func test_insert() throws {
        var tree = TextLineStorage<TextLine>()

        // Single Element
        tree.insert(line: TextLine(), atOffset: 0, length: 1, height: 50.0)
        XCTAssert(tree.length == 1, "Tree length incorrect")
        XCTAssert(tree.count == 1, "Tree count incorrect")
        XCTAssert(tree.height == 50.0, "Tree height incorrect")
        XCTAssert(tree.root?.right == nil && tree.root?.left == nil, "Somehow inserted an extra node.")
        try assertTreeMetadataCorrect(tree)

        // Insert into first
        tree = createBalancedTree()
        tree.insert(line: TextLine(), atOffset: 0, length: 1, height: 1.0)
        try assertTreeMetadataCorrect(tree)

        // Insert into last
        tree = createBalancedTree()
        tree.insert(line: TextLine(), atOffset: tree.length - 1, length: 1, height: 1.0)
        try assertTreeMetadataCorrect(tree)

        tree = createBalancedTree()
        tree.insert(line: TextLine(), atOffset: 45, length: 1, height: 1.0)
        try assertTreeMetadataCorrect(tree)
    }

    func test_update() throws {
        var tree = TextLineStorage<TextLine>()

        // Single Element
        tree.insert(line: TextLine(), atOffset: 0, length: 1, height: 1.0)
        tree.update(atOffset: 0, delta: 20, deltaHeight: 5.0)
        XCTAssertEqual(tree.length, 21, "Tree length incorrect")
        XCTAssertEqual(tree.count, 1, "Tree count incorrect")
        XCTAssertEqual(tree.height, 6, "Tree height incorrect")
        XCTAssert(tree.root?.right == nil && tree.root?.left == nil, "Somehow inserted an extra node.")
        try assertTreeMetadataCorrect(tree)

        // Update First
        tree = createBalancedTree()
        tree.update(atOffset: 0, delta: 12, deltaHeight: -0.5)
        XCTAssertEqual(tree.height, 14.5, "Tree height incorrect")
        XCTAssertEqual(tree.count, 15, "Tree count changed")
        XCTAssertEqual(tree.length, 132, "Tree length incorrect")
        XCTAssertEqual(tree.first?.range.length, 13, "First node wasn't updated correctly.")
        try assertTreeMetadataCorrect(tree)

        // Update Last
        tree = createBalancedTree()
        tree.update(atOffset: tree.length - 1, delta: -14, deltaHeight: 1.75)
        XCTAssertEqual(tree.height, 16.75, "Tree height incorrect")
        XCTAssertEqual(tree.count, 15, "Tree count changed")
        XCTAssertEqual(tree.length, 106, "Tree length incorrect")
        XCTAssertEqual(tree.last?.range.length, 1, "Last node wasn't updated correctly.")
        try assertTreeMetadataCorrect(tree)

        // Update middle
        tree = createBalancedTree()
        tree.update(atOffset: 45, delta: -9, deltaHeight: 1.0)
        XCTAssertEqual(tree.height, 16.0, "Tree height incorrect")
        XCTAssertEqual(tree.count, 15, "Tree count changed")
        XCTAssertEqual(tree.length, 111, "Tree length incorrect")
        XCTAssert(tree.root?.right?.left?.height == 2.0 && tree.root?.right?.left?.length == 1, "Node wasn't updated")
        try assertTreeMetadataCorrect(tree)

        // Update at random
        tree = createBalancedTree()
        for _ in 0..<20 {
            let delta = Int.random(in: 1..<20)
            let deltaHeight = Double.random(in: 0..<20.0)
            let originalHeight = tree.height
            let originalCount = tree.count
            let originalLength = tree.length
            tree.update(atOffset: Int.random(in: 0..<tree.length), delta: delta, deltaHeight: deltaHeight)
            XCTAssert(originalCount == tree.count, "Tree count should not change on update")
            XCTAssert(originalHeight + deltaHeight == tree.height, "Tree height incorrect")
            XCTAssert(originalLength + delta == tree.length, "Tree length incorrect")
            try assertTreeMetadataCorrect(tree)
        }
    }

    // swiftlint:disable:next function_body_length
    func test_delete() throws {
        var tree = TextLineStorage<TextLine>()

        // Single Element
        tree.insert(line: TextLine(), atOffset: 0, length: 1, height: 1.0)
        XCTAssert(tree.length == 1, "Tree length incorrect")
        tree.delete(lineAt: 0)
        XCTAssert(tree.length == 0, "Tree failed to delete single node")
        XCTAssert(tree.root == nil, "Tree root should be nil")
        try assertTreeMetadataCorrect(tree)

        // Delete first

        tree = createBalancedTree()
        tree.delete(lineAt: 0)
        XCTAssert(tree.count == 14, "Tree length incorrect")
        XCTAssert(tree.first?.range.length == 2, "Failed to delete leftmost node")
        try assertTreeMetadataCorrect(tree)

        // Delete last

        tree = createBalancedTree()
        tree.delete(lineAt: tree.length - 1)
        XCTAssert(tree.count == 14, "Tree length incorrect")
        XCTAssert(tree.last?.range.length == 14, "Failed to delete rightmost node")
        try assertTreeMetadataCorrect(tree)

        // Delete mid leaf

        tree = createBalancedTree()
        tree.delete(lineAt: 45)
        XCTAssert(tree.root?.right?.left?.length == 11, "Failed to remove node 10")
        XCTAssert(tree.root?.right?.leftSubtreeOffset == 20, "Failed to update metadata on parent of node 10")
        XCTAssert(tree.root?.right?.left?.right == nil, "Failed to replace node 10 with node 11")
        XCTAssert(tree.count == 14, "Tree length incorrect")
        try assertTreeMetadataCorrect(tree)

        tree = createBalancedTree()
        tree.delete(lineAt: 66)
        XCTAssert(tree.root?.right?.length == 13, "Failed to remove node 12")
        XCTAssert(tree.root?.right?.leftSubtreeOffset == 30, "Failed to update metadata on parent of node 13")
        XCTAssert(tree.root?.right?.left?.right?.left == nil, "Failed to replace node 12 with node 13")
        XCTAssert(tree.count == 14, "Tree length incorrect")
        try assertTreeMetadataCorrect(tree)

        // Delete root

        tree = createBalancedTree()
        tree.delete(lineAt: tree.root!.leftSubtreeOffset + 1)
        XCTAssert(tree.root?.color == .black, "Root color incorrect")
        XCTAssert(tree.root?.right?.left?.left == nil, "Replacement node was not moved to root")
        XCTAssert(tree.root?.leftSubtreeCount == 7, "Replacement node was not given correct metadata.")
        XCTAssert(tree.root?.leftSubtreeHeight == 7.0, "Replacement node was not given correct metadata.")
        XCTAssert(tree.root?.leftSubtreeOffset == 28, "Replacement node was not given correct metadata.")
        XCTAssert(tree.count == 14, "Tree length incorrect")
        try assertTreeMetadataCorrect(tree)

        // Delete a bunch of random

        for _ in 0..<20 {
            tree = createBalancedTree()
            var lastCount = 15
            while !tree.isEmpty {
                lastCount -= 1
                tree.delete(lineAt: Int.random(in: 0..<tree.count))
                XCTAssert(tree.count == lastCount, "Tree length incorrect")
                var last = -1
                for line in tree {
                    XCTAssert(line.range.length > last, "Out of order after deletion")
                    last = line.range.length
                }
                try assertTreeMetadataCorrect(tree)
            }
        }
    }

    /// A balanced tree whose line at index `i` is `i + 1` characters long and `widths[i]` wide.
    fileprivate func createMeasuredTree(widths: [CGFloat]) -> TextLineStorage<TextLine> {
        let tree = TextLineStorage<TextLine>()
        tree.build(
            from: widths.indices.map { .init(data: TextLine(), length: $0 + 1, height: 1.0) },
            estimatedLineHeight: 1.0
        )
        for (index, width) in widths.enumerated() {
            tree.setWidth(width, forLineAt: index)
        }
        return tree
    }

    fileprivate func lineStart(ofLineAt index: Int, in tree: TextLineStorage<TextLine>) throws -> Int {
        try XCTUnwrap(tree.getLine(atIndex: index)).range.location
    }

    func test_maxWidthIsTheWidestMeasuredLine() throws {
        let tree = createMeasuredTree(widths: [10, 40, 25, 5, 30])
        XCTAssertEqual(tree.maxWidth, 40)
        try assertTreeMetadataCorrect(tree)

        XCTAssertEqual(TextLineStorage<TextLine>().maxWidth, 0, "An empty tree has no width")
    }

    func test_narrowingTheWidestLineLowersMaxWidth() throws {
        let tree = createMeasuredTree(widths: [10, 40, 25, 5, 30])

        tree.setWidth(12, forLineAt: 1)
        XCTAssertEqual(tree.maxWidth, 30, "The next widest line takes over")
        try assertTreeMetadataCorrect(tree)

        tree.setWidth(0, forLineAt: 4)
        XCTAssertEqual(tree.maxWidth, 25, "A forgotten width counts as zero")
        try assertTreeMetadataCorrect(tree)
    }

    func test_deletingTheWidestLineLowersMaxWidth() throws {
        for index in 0..<15 {
            var widths = (0..<15).map { CGFloat($0 + 1) }
            widths[index] = 1_000
            let tree = createMeasuredTree(widths: widths)
            XCTAssertEqual(tree.maxWidth, 1_000)

            tree.delete(lineAt: try lineStart(ofLineAt: index, in: tree))

            widths.remove(at: index)
            XCTAssertEqual(tree.maxWidth, widths.max(), "Deleting line \(index) left a stale width")
            try assertTreeMetadataCorrect(tree)
        }
    }

    func test_resetWidthsForgetsEveryWidth() throws {
        let tree = createMeasuredTree(widths: [10, 40, 25, 5, 30])

        tree.resetWidths()

        XCTAssertEqual(tree.maxWidth, 0)
        try assertTreeMetadataCorrect(tree)
        tree.setWidth(7, forLineAt: 2)
        XCTAssertEqual(tree.maxWidth, 7, "Widths recorded after a reset count again")
    }

    /// Runs a long, reproducible sequence of inserts, deletes, length changes and width changes against a plain array,
    /// checking after every step that the tree's width aggregate and its per-node invariant agree with the array.
    ///
    /// Rotations and the two-child delete are where a width aggregate goes wrong, and a hand-written case reaches only
    /// the few shapes it was written for.
    func test_widthAggregateMatchesAModelThroughRandomEdits() throws {
        var generator = SeededGenerator(seed: 2709)
        let tree = TextLineStorage<TextLine>()
        var model: [(length: Int, width: CGFloat)] = []

        for _ in 0..<4_000 {
            let operation = model.isEmpty ? 0 : Int.random(in: 0..<4, using: &generator)
            switch operation {
            case 0:
                let index = Int.random(in: 0...model.count, using: &generator)
                let offset = model[..<index].reduce(0) { $0 + $1.length }
                let length = Int.random(in: 1...20, using: &generator)
                tree.insert(line: TextLine(), atOffset: offset, length: length, height: 1.0)
                model.insert((length, 0), at: index)
            case 1:
                let index = Int.random(in: 0..<model.count, using: &generator)
                tree.delete(lineAt: try lineStart(ofLineAt: index, in: tree))
                model.remove(at: index)
            case 2:
                let index = Int.random(in: 0..<model.count, using: &generator)
                let delta = Int.random(in: 1...5, using: &generator)
                tree.update(atOffset: try lineStart(ofLineAt: index, in: tree), delta: delta, deltaHeight: 0)
                model[index].length += delta
            default:
                let index = Int.random(in: 0..<model.count, using: &generator)
                let width = CGFloat(Int.random(in: 0...500, using: &generator))
                tree.setWidth(width, forLineAt: index)
                model[index].width = width
            }

            XCTAssertEqual(tree.maxWidth, model.map(\.width).max() ?? 0)
            XCTAssertEqual(tree.map(\.range.length), model.map(\.length), "Lines out of order")
            try assertTreeMetadataCorrect(tree)
        }
    }

    func test_insertPerformance() {
        let tree = TextLineStorage<TextLine>()
        var lines: [TextLineStorage<TextLine>.BuildItem] = []
        for idx in 0..<250_000 {
            lines.append(TextLineStorage<TextLine>.BuildItem(
                data: TextLine(),
                length: idx + 1,
                height: 0.0
            ))
        }
        tree.build(from: lines, estimatedLineHeight: 1.0)
        // Measure time when inserting randomly into an already built tree.
        // Start    0.667s
        // 10/6/23  0.563s  -15.59%
        measure {
            for _ in 0..<100_000 {
                tree.insert(
                    line: TextLine(), atOffset: Int.random(in: 0..<tree.length), length: 1, height: 0.0
                )
            }
        }
    }

    func test_insertFastPerformance() {
        let tree = TextLineStorage<TextLine>()
        let lines: [TextLineStorage<TextLine>.BuildItem] = (0..<250_000).map {
            TextLineStorage<TextLine>.BuildItem(
                data: TextLine(),
                length: $0 + 1,
                height: 0.0
            )
        }
        // Start    0.113s
        measure {
            tree.build(from: lines, estimatedLineHeight: 1.0)
        }
    }

    func test_iterationPerformance() {
        let tree = TextLineStorage<TextLine>()
        var lines: [TextLineStorage<TextLine>.BuildItem] = []
        for idx in 0..<100_000 {
            lines.append(TextLineStorage<TextLine>.BuildItem(
                data: TextLine(),
                length: idx + 1,
                height: 0.0
            ))
        }
        tree.build(from: lines, estimatedLineHeight: 1.0)
        // Start    0.181s
        measure {
            for line in tree {
                _ = line
            }
        }
    }

    func test_transplantWithExistingLeftNodes() throws { // swiftlint:disable:this function_body_length
        typealias Storage = TextLineStorage<UUID>
        typealias Node = TextLineStorage<UUID>.Node
        // Test that when transplanting a node with no left nodes, with a node with left nodes, that
        // the resulting tree has valid 'left_' metadata
        //         1
        //       /    \
        //     7        2
        //            /
        //           3     ← this will be moved, this test ensures 4 retains it's left subtree count
        //             \
        //              4
        //             | |
        //             5 6

        let node5 = Node(
            length: 5,
            data: UUID(),
            leftSubtreeOffset: 0,
            leftSubtreeHeight: 0,
            leftSubtreeCount: 0,
            height: 1,
            left: nil,
            right: nil,
            parent: nil,
            color: .black
        )

        let node6 = Node(
            length: 6,
            data: UUID(),
            leftSubtreeOffset: 0,
            leftSubtreeHeight: 0,
            leftSubtreeCount: 0,
            height: 1,
            left: nil,
            right: nil,
            parent: nil,
            color: .black
        )

        let node4 = Node(
            length: 4,
            data: UUID(),
            leftSubtreeOffset: 5,
            leftSubtreeHeight: 1,
            leftSubtreeCount: 1, // node5 is on the left
            height: 1,
            left: node5,
            right: node6,
            parent: nil,
            color: .black
        )
        node5.parent = node4
        node6.parent = node4

        let node3 = Node(
            length: 3,
            data: UUID(),
            leftSubtreeOffset: 0,
            leftSubtreeHeight: 0,
            leftSubtreeCount: 0,
            height: 1,
            left: nil,
            right: node4,
            parent: nil,
            color: .black
        )
        node4.parent = node3

        let node2 = Node(
            length: 2,
            data: UUID(),
            leftSubtreeOffset: 18,
            leftSubtreeHeight: 4,
            leftSubtreeCount: 4, // node3 is on the left
            height: 1,
            left: node3,
            right: nil,
            parent: nil,
            color: .black
        )
        node3.parent = node2

        let node7 = Node(length: 7, data: UUID(), height: 1)

        let node1 = Node(
            length: 1,
            data: UUID(),
            leftSubtreeOffset: 7,
            leftSubtreeHeight: 1,
            leftSubtreeCount: 1,
            height: 1,
            left: node7,
            right: node2,
            parent: nil,
            color: .black
        )
        node2.parent = node1

        let storage = Storage(root: node1, count: 7, length: 28, height: 7)

        storage.delete(lineAt: 7) // Delete the root

        try assertTreeMetadataCorrect(storage)
    }
}

/// A small deterministic generator, so a failing random sequence can be replayed exactly.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
