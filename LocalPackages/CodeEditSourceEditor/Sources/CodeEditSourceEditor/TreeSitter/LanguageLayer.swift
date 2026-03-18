//
//  TreeSitterClient+LanguageLayer.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 3/8/23.
//

import Foundation
import CodeEditLanguages
import SwiftTreeSitter
import TreeSitter

extension Parser {
    func reset() {
        let mirror = Mirror(reflecting: self)
        for case let (label?, value) in mirror.children {
            if label == "internalParser", let value = value as? OpaquePointer {
                ts_parser_reset(value)
            }
        }
    }
}

public class LanguageLayer: Hashable {
    /// Initialize a language layer
    /// - Parameters:
    ///   - id: The ID of the layer.
    ///   - tsLanguage: The tree sitter language reference.
    ///   - parser: A parser to use for the layer.
    ///   - supportsInjections: Set to true when the langauge supports the `injections` query.
    ///   - tree: The tree-sitter tree generated while editing/parsing a document.
    ///   - languageQuery: The language query used for fetching the associated `queries.scm` file
    ///   - ranges: All ranges this layer acts on. Must be kept in order and w/o overlap.
    init(
        id: TreeSitterLanguage,
        tsLanguage: Language?,
        parser: Parser,
        supportsInjections: Bool,
        tree: MutableTree? = nil,
        languageQuery: Query? = nil,
        ranges: [NSRange]
    ) {
        self.id = id
        self.tsLanguage = tsLanguage
        self.parser = parser
        self.supportsInjections = supportsInjections
        self.tree = tree
        self.languageQuery = languageQuery
        self.ranges = ranges

        self.parser.timeout = TreeSitterClient.Constants.parserTimeout
    }

    let id: TreeSitterLanguage
    let tsLanguage: Language?
    let parser: Parser
    let supportsInjections: Bool
    var tree: MutableTree?
    var languageQuery: Query?
    var ranges: [NSRange]

    func copy() -> LanguageLayer {
        return LanguageLayer(
            id: id,
            tsLanguage: tsLanguage,
            parser: parser,
            supportsInjections: supportsInjections,
            tree: tree?.mutableCopy(),
            languageQuery: languageQuery,
            ranges: ranges
        )
    }

    public static func == (lhs: LanguageLayer, rhs: LanguageLayer) -> Bool {
        return lhs.id == rhs.id && lhs.ranges == rhs.ranges
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(ranges)
    }

    /// Calculates a series of ranges that have been invalidated by a given edit.
    /// - Parameters:
    ///   - edit: The edit to act on.
    ///   - timeout: The maximum time interval the parser can run before halting.
    ///   - readBlock: A callback for fetching blocks of text.
    /// - Returns: An array of distinct `NSRanges` that need to be re-highlighted.
    func findChangedByteRanges(
        edits: [InputEdit],
        timeout: TimeInterval?,
        readBlock: @escaping Parser.ReadBlock
    ) -> [NSRange] {
        parser.timeout = timeout ?? 0

        let (newTree, didCancel) = calculateNewState(
            tree: self.tree?.mutableCopy(),
            parser: self.parser,
            edits: edits,
            readBlock: readBlock
        )

        if didCancel {
            return []
        }

        if self.tree == nil && newTree == nil {
            // There was no existing tree, make a new one and return all indexes.
            self.tree = parser.parse(tree: nil as Tree?, readBlock: readBlock)
            return [self.tree?.rootNode?.range ?? .zero]
        }

        let ranges = changedByteRanges(self.tree, newTree).map { $0.range }

        self.tree = newTree

        return ranges
    }

    /// Applies the edit to the current `tree` and returns the old tree and a copy of the current tree with the
    /// processed edit.
    /// - Parameters:
    ///   - tree: The tree before an edit used to parse the new tree.
    ///   - parser: The parser used to parse the new tree.
    ///   - edit: The edit to apply.
    ///   - readBlock: The block to use to read text.
    ///   - skipParse: Set to true to skip any parsing steps and only apply the edit to the tree.
    /// - Returns: The new tree, if it was parsed, and a boolean indicating if parsing was skipped or cancelled.
    internal func calculateNewState(
        tree: MutableTree?,
        parser: Parser,
        edits: [InputEdit],
        readBlock: @escaping Parser.ReadBlock
    ) -> (tree: MutableTree?, didCancel: Bool) {
        guard let tree else {
            return (nil, false)
        }

        // Apply the edits to the old tree
        for edit in edits {
            tree.edit(edit)
        }

        let start = ContinuousClock.now
        var wasLongParse = false

        // Check every timeout to see if the task is canceled to avoid parsing after the editor has been closed.
        // We can continue a parse after a timeout causes it to cancel by calling parse on the same tree.
        var newTree: MutableTree?
        while newTree == nil {
            if Task.isCancelled {
                parser.reset()
                return (nil, true)
            }
            if start.duration(to: .now) > TreeSitterClient.Constants.longParseTimeout {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: TreeSitterClient.Constants.longParse, object: nil)
                }
                wasLongParse = true
            }
            newTree = DispatchQueue.waitMainIfNot { parser.parse(tree: tree, readBlock: readBlock) }
        }

        if wasLongParse {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: TreeSitterClient.Constants.longParseFinished, object: nil)
            }
        }

        return (newTree, false)
    }

    /// Calculates the changed byte ranges between two trees.
    /// - Parameters:
    ///   - lhs: The first (older) tree.
    ///   - rhs: The second (newer) tree.
    /// - Returns: Any changed ranges.
    internal func changedByteRanges(_ lhs: MutableTree?, _ rhs: MutableTree?) -> [Range<UInt32>] {
        switch (lhs, rhs) {
        case (let tree1?, let tree2?):
            return tree1.changedRanges(from: tree2).map({ $0.bytes })
        case (nil, let tree2?):
            let range = tree2.rootNode?.byteRange

            return range.flatMap({ [$0] }) ?? []
        case (_, nil):
            return []
        }
    }

    enum Error: Swift.Error, LocalizedError {
        case parserTimeout
    }
}
