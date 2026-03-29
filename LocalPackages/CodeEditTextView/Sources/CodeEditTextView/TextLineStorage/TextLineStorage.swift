//
//  TextLayoutLineStorage.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/25/23.
//

import Foundation

// Disabling the file length here due to the fact that we want to keep certain methods private even to this package.
// Specifically, all rotation methods, fixup methods, and internal search methods must be kept private.
// swiftlint:disable file_length

// There is some ugly `Unmanaged` code in this class. This is due to the fact that Swift often has a hard time
// optimizing retain/release calls for object trees. For instance, the `metaFixup` method has a lot of retain/release
// calls to each node/parent as we do a little walk up the tree.
//
// Using Unmanaged references resulted in a -15% decrease (0.667s -> 0.563s) in the
// TextLayoutLineStorageTests.test_insertPerformance benchmark when first changed to use Unmanaged.
//
// See:
// - https://github.com/apple/swift/blob/main/docs/OptimizationTips.rst#unsafe-code
// - https://forums.swift.org/t/improving-linked-list-performance-swift-release-and-swift-retain-overhead/17205

/// Implements a red-black tree for efficiently editing, storing and retrieving lines of text in a document.
public final class TextLineStorage<Data: Identifiable> {
    private enum MetaFixupAction {
        case inserted
        case deleted
        case none
    }

    var root: Node<Data>?

    /// The number of characters in the storage object.
    private(set) public var length: Int = 0
    /// The number of lines in the storage object
    private(set) public var count: Int = 0

    public var isEmpty: Bool { count == 0 }

    public var height: CGFloat = 0

    public var first: TextLinePosition? {
        guard count > 0, let position = search(forIndex: 0) else { return nil }
        return TextLinePosition(position: position)
    }

    public var last: TextLinePosition? {
        guard count > 0, let position = search(forIndex: count - 1) else { return nil }
        return TextLinePosition(position: position)
    }

    private var lastNode: NodePosition? {
        guard count > 0, let position = search(forIndex: count - 1) else { return nil }
        return position
    }

    public init() { }

    init(root: Node<Data>, count: Int, length: Int, height: CGFloat) {
        self.root = root
        self.count = count
        self.length = length
        self.height = height
    }

    // MARK: - Public Methods

    /// Inserts a new line for the given range.
    /// - Complexity: `O(log n)` where `n` is the number of lines in the storage object.
    /// - Parameters:
    ///   - line: The text line to insert
    ///   - index: The offset to insert the line at.
    ///   - length: The length of the new line.
    ///   - height: The height of the new line.
    public func insert(line: Data, atOffset index: Int, length: Int, height: CGFloat) {
        assert(index >= 0 && index <= self.length, "Invalid index, expected between 0 and \(self.length). Got \(index)")
        defer {
            self.count += 1
            self.length += length
            self.height += height
        }

        let insertedNode = Node(length: length, data: line, height: height)
        guard root != nil else {
            root = insertedNode
            return
        }
        insertedNode.color = .red

        var currentNode: Unmanaged<Node<Data>> = Unmanaged<Node<Data>>.passUnretained(root!)
        var shouldContinue = true
        var currentOffset: Int = root?.leftSubtreeOffset ?? 0
        while shouldContinue {
            let node = currentNode.takeUnretainedValue()
            if currentOffset >= index {
                if node.left != nil {
                    currentNode = Unmanaged<Node<Data>>.passUnretained(node.left!)
                    currentOffset = (currentOffset - node.leftSubtreeOffset) + (node.left?.leftSubtreeOffset ?? 0)
                } else {
                    node.left = insertedNode
                    insertedNode.parent = node
                    shouldContinue = false
                }
            } else {
                if node.right != nil {
                    currentNode = Unmanaged<Node<Data>>.passUnretained(node.right!)
                    currentOffset += node.length + (node.right?.leftSubtreeOffset ?? 0)
                } else {
                    node.right = insertedNode
                    insertedNode.parent = node
                    shouldContinue = false
                }
            }
        }

        metaFixup(
            startingAt: insertedNode,
            delta: insertedNode.length,
            deltaHeight: insertedNode.height,
            nodeAction: .inserted
        )
        insertFixup(node: insertedNode)
    }

    /// Fetches a line for the given offset.
    ///
    /// - Complexity: `O(log n)`
    /// - Parameter offset: The offset to fetch for.
    /// - Returns:A  ``TextLineStorage/TextLinePosition`` struct with relevant position and line information.
    public func getLine(atOffset offset: Int) -> TextLinePosition? {
        guard let nodePosition = search(for: offset) else { return nil }
        return TextLinePosition(position: nodePosition)
    }

    /// Fetches a line for the given index.
    ///
    /// - Complexity: `O(log n)`
    /// - Parameter index: The index to fetch for.
    /// - Returns: A  ``TextLineStorage/TextLinePosition`` struct with relevant position and line information.
    public func getLine(atIndex index: Int) -> TextLinePosition? {
        guard let nodePosition = search(forIndex: index) else { return nil }
        return TextLinePosition(position: nodePosition)
    }

    /// Fetches a line for the given `y` value.
    ///
    /// - Complexity: `O(log n)`
    /// - Parameter position: The position to fetch for.
    /// - Returns: A  ``TextLineStorage/TextLinePosition`` struct with relevant position and line information.
    public func getLine(atPosition posY: CGFloat) -> TextLinePosition? {
        guard posY < height else {
            return last
        }

        var currentNode = root
        var currentOffset: Int = root?.leftSubtreeOffset ?? 0
        var currentYPosition: CGFloat = root?.leftSubtreeHeight ?? 0
        var currentIndex: Int = root?.leftSubtreeCount ?? 0
        while let node = currentNode {
            // If index is in the range [currentOffset..<currentOffset + length) it's in the line
            if posY >= currentYPosition && posY < currentYPosition + node.height {
                return TextLinePosition(
                    data: node.data,
                    range: NSRange(location: currentOffset, length: node.length),
                    yPos: currentYPosition,
                    height: node.height,
                    index: currentIndex
                )
            } else if currentYPosition > posY {
                currentNode = node.left
                currentOffset = (currentOffset - node.leftSubtreeOffset) + (node.left?.leftSubtreeOffset ?? 0)
                currentYPosition = (currentYPosition - node.leftSubtreeHeight) + (node.left?.leftSubtreeHeight ?? 0)
                currentIndex = (currentIndex - node.leftSubtreeCount) + (node.left?.leftSubtreeCount ?? 0)
            } else if node.leftSubtreeHeight < posY {
                currentNode = node.right
                currentOffset += node.length + (node.right?.leftSubtreeOffset ?? 0)
                currentYPosition += node.height + (node.right?.leftSubtreeHeight ?? 0)
                currentIndex += 1 + (node.right?.leftSubtreeCount ?? 0)
            } else {
                currentNode = nil
            }
        }

        return nil
    }

    /// Applies a length change at the given index.
    ///
    /// If a character was deleted, delta should be negative.
    /// The `index` parameter should represent where the edit began.
    ///
    /// Lines will be deleted if the delta is both negative and encompasses the entire line.
    ///
    /// If the delta goes beyond the line's range, an error will be thrown.
    /// - Complexity `O(m log n)` where `m` is the number of lines that need to be deleted as a result of this update.
    ///              and `n` is the number of lines stored in the tree.
    /// - Parameters:
    ///   - offset: The offset where the edit began
    ///   - delta: The change in length of the document. Negative for deletes, positive for insertions.
    ///   - deltaHeight: The change in height of the document.
    public func update(atOffset offset: Int, delta: Int, deltaHeight: CGFloat) {
        assert(
            offset >= 0 && offset <= self.length,
            "Invalid index, expected between 0 and \(self.length). Got \(offset)"
        )
        assert(delta != 0 || deltaHeight != 0, "Delta must be non-0")
        let position: NodePosition?
        if offset == self.length { // Updates at the end of the document are valid
            position = lastNode
        } else {
            position = search(for: offset)
        }
        guard let position else {
            assertionFailure("No line found at index \(offset)")
            return
        }
        if delta < 0 {
            assert(
                offset - position.textPos > delta,
                "Delta too large. Deleting \(-delta) from line at position \(offset) extends beyond the line's range."
            )
        }
        length += delta
        height += deltaHeight
        position.node.length += delta
        position.node.height += deltaHeight
        metaFixup(startingAt: position.node, delta: delta, deltaHeight: deltaHeight)
    }

    /// Deletes the line containing the given index.
    ///
    /// Will exit silently if a line could not be found for the given index, and throw an assertion error if the index
    /// is out of bounds.
    /// - Parameter index: The index to delete a line at.
    public func delete(lineAt index: Int) {
        assert(index >= 0 && index <= self.length, "Invalid index, expected between 0 and \(self.length). Got \(index)")
        guard count > 1 else {
            removeAll()
            return
        }
        guard let node = search(for: index)?.node else {
            assertionFailure("Failed to find node for index: \(index)")
            return
        }
        count -= 1
        length -= node.length
        height -= node.height
        deleteNode(node)
    }

    public func removeAll() {
        root = nil
        count = 0
        length = 0
        height = 0
    }

    /// Efficiently builds the tree from the given array of lines.
    /// - Note: Calls ``TextLineStorage/removeAll()`` before building.
    /// - Parameter lines: The lines to use to build the tree.
    public func build(from lines: borrowing [BuildItem], estimatedLineHeight: CGFloat) {
        removeAll()
        root = build(lines: lines, estimatedLineHeight: estimatedLineHeight, left: 0, right: lines.count, parent: nil).0
        count = lines.count
    }

    /// Recursively builds a subtree given an array of sorted lines, and a left and right indexes.
    /// - Parameters:
    ///   - lines: The lines to use to build the subtree.
    ///   - estimatedLineHeight: An estimated line height to add to the allocated nodes.
    ///   - left: The left index to use.
    ///   - right: The right index to use.
    ///   - parent: The parent of the subtree, `nil` if this is the root.
    /// - Returns: A node, if available, along with it's subtree's height and offset.
    private func build(
        lines: borrowing [BuildItem],
        estimatedLineHeight: CGFloat,
        left: Int,
        right: Int,
        parent: Node<Data>?
    ) -> (Node<Data>?, Int?, CGFloat?, Int) { // swiftlint:disable:this large_tuple
        guard left < right else { return (nil, nil, nil, 0) }
        let mid = left + (right - left)/2
        let node = Node(
            length: lines[mid].length,
            data: lines[mid].data,
            leftSubtreeOffset: 0,
            leftSubtreeHeight: 0,
            leftSubtreeCount: 0,
            height: lines[mid].height ?? estimatedLineHeight,
            color: .black
        )
        node.parent = parent

        let (left, leftOffset, leftHeight, leftCount) = build(
            lines: lines,
            estimatedLineHeight: estimatedLineHeight,
            left: left,
            right: mid,
            parent: node
        )
        let (right, rightOffset, rightHeight, rightCount) = build(
            lines: lines,
            estimatedLineHeight: estimatedLineHeight,
            left: mid + 1,
            right: right,
            parent: node
        )
        node.left = left
        node.right = right

        if node.left == nil && node.right == nil {
            node.color = .red
        }

        length += node.length
        height += node.height
        node.leftSubtreeOffset = leftOffset ?? 0
        node.leftSubtreeHeight = leftHeight ?? 0
        node.leftSubtreeCount = leftCount

        return (
            node,
            node.length + (leftOffset ?? 0) + (rightOffset ?? 0),
            node.height + (leftHeight ?? 0) + (rightHeight ?? 0),
            1 + leftCount + rightCount
        )
    }
}

private extension TextLineStorage {
    // MARK: - Search

    /// Searches for the given offset.
    /// - Parameter offset: The offset to look for in the document.
    /// - Returns: A tuple containing a node if it was found, and the offset of the node in the document.
    func search(for offset: Int) -> NodePosition? {
        var currentNode = root
        var currentOffset: Int = root?.leftSubtreeOffset ?? 0
        var currentYPosition: CGFloat = root?.leftSubtreeHeight ?? 0
        var currentIndex: Int = root?.leftSubtreeCount ?? 0
        while let node = currentNode {
            // If index is in the range [currentOffset..<currentOffset + length) it's in the line
            if offset == currentOffset || (offset >= currentOffset && offset < currentOffset + node.length) {
                return NodePosition(node: node, yPos: currentYPosition, textPos: currentOffset, index: currentIndex)
            } else if currentOffset > offset {
                currentNode = node.left
                currentOffset = (currentOffset - node.leftSubtreeOffset) + (node.left?.leftSubtreeOffset ?? 0)
                currentYPosition = (currentYPosition - node.leftSubtreeHeight) + (node.left?.leftSubtreeHeight ?? 0)
                currentIndex = (currentIndex - node.leftSubtreeCount) + (node.left?.leftSubtreeCount ?? 0)
            } else if node.leftSubtreeOffset < offset {
                currentNode = node.right
                currentOffset += node.length + (node.right?.leftSubtreeOffset ?? 0)
                currentYPosition += node.height + (node.right?.leftSubtreeHeight ?? 0)
                currentIndex += 1 + (node.right?.leftSubtreeCount ?? 0)
            } else {
                currentNode = nil
            }
        }
        return nil
    }

    /// Searches for the given index.
    /// - Parameter index: The index to look for in the document.
    /// - Returns: A tuple containing a node if it was found, and the offset of the node in the document.
    func search(forIndex index: Int) -> NodePosition? {
        var currentNode = root
        var currentOffset: Int = root?.leftSubtreeOffset ?? 0
        var currentYPosition: CGFloat = root?.leftSubtreeHeight ?? 0
        var currentIndex: Int = root?.leftSubtreeCount ?? 0
        while let node = currentNode {
            if index == currentIndex {
                return NodePosition(node: node, yPos: currentYPosition, textPos: currentOffset, index: currentIndex)
            } else if currentIndex > index {
                currentNode = node.left
                currentOffset = (currentOffset - node.leftSubtreeOffset) + (node.left?.leftSubtreeOffset ?? 0)
                currentYPosition = (currentYPosition - node.leftSubtreeHeight) + (node.left?.leftSubtreeHeight ?? 0)
                currentIndex = (currentIndex - node.leftSubtreeCount) + (node.left?.leftSubtreeCount ?? 0)
            } else {
                currentNode = node.right
                currentOffset += node.length + (node.right?.leftSubtreeOffset ?? 0)
                currentYPosition += node.height + (node.right?.leftSubtreeHeight ?? 0)
                currentIndex += 1 + (node.right?.leftSubtreeCount ?? 0)
            }
        }
        return nil
    }

    // MARK: - Delete

    /// A basic RB-Tree node removal with specialization for node metadata.
    /// - Parameter nodeZ: The node to remove.
    func deleteNode(_ nodeZ: Node<Data>) {
        metaFixup(startingAt: nodeZ, delta: -nodeZ.length, deltaHeight: -nodeZ.height, nodeAction: .deleted)

        var nodeY = nodeZ
        var nodeX: Node<Data>?
        var originalColor = nodeY.color

        if nodeZ.left == nil || nodeZ.right == nil {
            nodeX = nodeZ.right ?? nodeZ.left
            transplant(nodeZ, with: nodeX)
        } else {
            nodeY = nodeZ.right!.minimum()

            // Delete nodeY from it's original place in the tree.
            metaFixup(startingAt: nodeY, delta: -nodeY.length, deltaHeight: -nodeY.height, nodeAction: .deleted)

            originalColor = nodeY.color
            nodeX = nodeY.right
            if nodeY.parent === nodeZ {
                nodeX?.parent = nodeY
            } else {
                transplant(nodeY, with: nodeY.right)

                nodeY.right?.leftSubtreeCount += nodeY.leftSubtreeCount
                nodeY.right?.leftSubtreeHeight += nodeY.leftSubtreeHeight
                nodeY.right?.leftSubtreeOffset += nodeY.leftSubtreeOffset

                nodeY.right = nodeZ.right
                nodeY.right?.parent = nodeY
            }
            transplant(nodeZ, with: nodeY)
            nodeY.left = nodeZ.left
            nodeY.left?.parent = nodeY
            nodeY.color = nodeZ.color
            nodeY.leftSubtreeCount = nodeZ.leftSubtreeCount
            nodeY.leftSubtreeHeight = nodeZ.leftSubtreeHeight
            nodeY.leftSubtreeOffset = nodeZ.leftSubtreeOffset

            // We've inserted nodeY again into a new spot. Update tree meta
            metaFixup(startingAt: nodeY, delta: nodeY.length, deltaHeight: nodeY.height, nodeAction: .inserted)
        }

        if originalColor == .black, let nodeX {
            deleteFixup(node: nodeX)
        }
    }

    // MARK: - Fixup

    func insertFixup(node: Node<Data>) {
        var nextNode: Node<Data>? = node
        while var nodeX = nextNode, nodeX !== root, let nodeXParent = nodeX.parent, nodeXParent.color == .red {
            let nodeY = nodeXParent.sibling()
            if isLeftChild(nodeXParent) {
                if nodeY?.color == .red {
                    nodeXParent.color = .black
                    nodeY?.color = .black
                    nodeX.parent?.parent?.color = .red
                    nextNode = nodeX.parent?.parent
                } else {
                    if isRightChild(nodeX) {
                        nodeX = nodeXParent
                        leftRotate(node: nodeX)
                    }

                    nodeX.parent?.color = .black
                    nodeX.parent?.parent?.color = .red
                    if let grandparent = nodeX.parent?.parent {
                        rightRotate(node: grandparent)
                    }
                }
            } else {
                if nodeY?.color == .red {
                    nodeXParent.color = .black
                    nodeY?.color = .black
                    nodeX.parent?.parent?.color = .red
                    nextNode = nodeX.parent?.parent
                } else {
                    if isLeftChild(nodeX) {
                        nodeX = nodeXParent
                        rightRotate(node: nodeX)
                    }

                    nodeX.parent?.color = .black
                    nodeX.parent?.parent?.color = .red
                    if let grandparent = nodeX.parent?.parent {
                        leftRotate(node: grandparent)
                    }
                }
            }
        }

        root?.color = .black
    }

    func deleteFixup(node: Node<Data>) {
        var nodeX: Node<Data>? = node
        while let node = nodeX, node !== root, node.color == .black {
            var sibling = node.sibling()
            if sibling?.color == .red {
                sibling?.color = .black
                node.parent?.color = .red
                if isLeftChild(node) {
                    leftRotate(node: node)
                } else {
                    rightRotate(node: node)
                }
                sibling = node.sibling()
            }

            if sibling?.left?.color == .black && sibling?.right?.color == .black {
                sibling?.color = .red
                nodeX = node.parent
            } else {
                if isLeftChild(node) {
                    if sibling?.right?.color == .black {
                        sibling?.left?.color = .black
                        sibling?.color = .red
                        if let sibling {
                            rightRotate(node: sibling)
                        }
                        sibling = node.parent?.right
                    }
                    sibling?.color = node.parent?.color ?? .black
                    node.parent?.color = .black
                    sibling?.right?.color = .black
                    leftRotate(node: node)
                    nodeX = root
                } else {
                    if sibling?.left?.color == .black {
                        sibling?.left?.color = .black
                        sibling?.color = .red
                        if let sibling {
                            leftRotate(node: sibling)
                        }
                        sibling = node.parent?.left
                    }
                    sibling?.color = node.parent?.color ?? .black
                    node.parent?.color = .black
                    sibling?.left?.color = .black
                    rightRotate(node: node)
                    nodeX = root
                }
            }
        }
        nodeX?.color = .black
    }

    /// Walk up the tree, updating any `leftSubtree` metadata.
    private func metaFixup(
        startingAt node: borrowing Node<Data>,
        delta: Int,
        deltaHeight: CGFloat,
        nodeAction: MetaFixupAction = .none
    ) {
        guard node.parent != nil, root != nil else { return }
        let rootRef = Unmanaged<Node<Data>>.passUnretained(root!)
        var ref = Unmanaged<Node<Data>>.passUnretained(node)
        while let node = ref._withUnsafeGuaranteedRef({ $0.parent }),
              ref.takeUnretainedValue() !== rootRef.takeUnretainedValue() {
            if node.left === ref.takeUnretainedValue() {
                node.leftSubtreeOffset += delta
                node.leftSubtreeHeight += deltaHeight
                switch nodeAction {
                case .inserted:
                    node.leftSubtreeCount += 1
                case .deleted:
                    node.leftSubtreeCount -= 1
                case .none:
                    break
                }
            }
            if node.parent != nil {
                ref = Unmanaged.passUnretained(node)
            } else {
                return
            }
        }
    }
}

// MARK: - Rotations

private extension TextLineStorage {
    func rightRotate(node: Node<Data>) {
        rotate(node: node, left: false)
    }

    func leftRotate(node: Node<Data>) {
        rotate(node: node, left: true)
    }

    func rotate(node: Node<Data>, left: Bool) {
        var nodeY: Node<Data>?

        if left {
            nodeY = node.right
            guard nodeY != nil else { return }
            nodeY?.leftSubtreeOffset += node.leftSubtreeOffset + node.length
            nodeY?.leftSubtreeHeight += node.leftSubtreeHeight + node.height
            nodeY?.leftSubtreeCount += node.leftSubtreeCount + 1
            node.right = nodeY?.left
            node.right?.parent = node
        } else {
            nodeY = node.left
            guard nodeY != nil else { return }
            node.left = nodeY?.right
            node.left?.parent = node
        }

        nodeY?.parent = node.parent
        if node.parent == nil {
            if let node = nodeY {
                 root = node
            }
        } else if isLeftChild(node) {
            node.parent?.left = nodeY
        } else if isRightChild(node) {
            node.parent?.right = nodeY
        }

        if left {
            nodeY?.left = node
        } else {
            nodeY?.right = node
            let metadata = getSubtreeMeta(startingAt: node.left)
            node.leftSubtreeOffset = metadata.offset
            node.leftSubtreeHeight = metadata.height
            node.leftSubtreeCount = metadata.count
        }
        node.parent = nodeY
    }

    /// Finds the correct subtree metadata starting at a node.
    /// - Complexity: `O(log n)` where `n` is the number of nodes in the tree.
    /// - Parameter node: The node to start finding metadata for.
    /// - Returns: The metadata representing the entire subtree including `node`.
    func getSubtreeMeta(startingAt node: Node<Data>?) -> NodeSubtreeMetadata {
        guard let node else { return .zero }
        return NodeSubtreeMetadata(
            height: node.height + node.leftSubtreeHeight,
            offset: node.length + node.leftSubtreeOffset,
            count: 1 + node.leftSubtreeCount
        ) + getSubtreeMeta(startingAt: node.right)
    }
}

// swiftlint:enable file_length
