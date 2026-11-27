//
//  TreeSitterClient+LanguageLayer.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 3/8/23.
//

import Foundation
import SwiftTreeSitter
import TableProGrammars
import TreeSitter

/// What a layer's parser is in the middle of, shared by every copy of the layer since they share the parser.
final class ParseSession {
    /// The text revision a parse that timed out was reading. Calling `parse` again over the same text resumes it;
    /// any other parse resets the parser first, or tree-sitter would resume over text that has since changed.
    var outstandingRevision: Int?
}

/// How a layer's parse ended.
enum LayerParseResult {
    case parsed([NSRange])
    /// The budgeted parse ran out of time; the parser holds it for the same revision to resume.
    case timedOut
    case cancelled
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
        id: GrammarID,
        tsLanguage: Language?,
        parser: Parser,
        supportsInjections: Bool,
        tree: MutableTree? = nil,
        languageQuery: Query? = nil,
        ranges: [NSRange],
        session: ParseSession = ParseSession()
    ) {
        self.id = id
        self.session = session
        self.tsLanguage = tsLanguage
        self.parser = parser
        self.supportsInjections = supportsInjections
        self.tree = tree
        self.languageQuery = languageQuery
        self.ranges = ranges

        self.parser.timeout = TreeSitterClient.Constants.parserTimeout
    }

    let id: GrammarID
    let tsLanguage: Language?
    let parser: Parser
    let supportsInjections: Bool
    let session: ParseSession
    var tree: MutableTree?
    var languageQuery: Query?
    var ranges: [NSRange]

    func copy() -> LanguageLayer {
        LanguageLayer(
            id: id,
            tsLanguage: tsLanguage,
            parser: parser,
            supportsInjections: supportsInjections,
            tree: tree?.mutableCopy(),
            languageQuery: languageQuery,
            ranges: ranges,
            session: session
        )
    }

    public static func == (lhs: LanguageLayer, rhs: LanguageLayer) -> Bool {
        lhs.id == rhs.id && lhs.ranges == rhs.ranges
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(ranges)
    }

    /// Calculates a series of ranges that have been invalidated by a given edit.
    /// - Parameters:
    ///   - edits: The edits to act on.
    ///   - revision: The text revision `readBlock` reads, which identifies a parse to resume.
    ///   - budget: How long the parse may run before it stops and is left to resume. `nil` runs it to the end,
    ///             checking for cancellation every ``TreeSitterClient/Constants/parserTimeout``.
    ///   - readBlock: A callback for fetching blocks of text.
    /// - Returns: The distinct `NSRanges` that need to be re-highlighted, or why there are none.
    func findChangedByteRanges(
        edits: [InputEdit],
        revision: Int,
        budget: TimeInterval?,
        readBlock: @escaping Parser.ReadBlock
    ) -> LayerParseResult {
        if session.outstandingRevision != nil, session.outstandingRevision != revision {
            parser.reset()
        }
        session.outstandingRevision = nil

        guard let oldTree = self.tree?.mutableCopy() else {
            // There was no existing tree, make a new one and return all indexes.
            parser.timeout = budget ?? 0
            guard let tree = parser.parse(tree: nil as Tree?, readBlock: readBlock) else {
                guard budget != nil else { return .cancelled }
                session.outstandingRevision = revision
                return .timedOut
            }
            self.tree = tree
            return .parsed([tree.rootNode?.range ?? .zero])
        }
        for edit in edits {
            oldTree.edit(edit)
        }

        parser.timeout = budget ?? TreeSitterClient.Constants.parserTimeout
        guard let newTree = parse(after: oldTree, budgeted: budget != nil, readBlock: readBlock) else {
            if budget != nil, !Task.isCancelled {
                session.outstandingRevision = revision
                return .timedOut
            }
            return .cancelled
        }

        // Tree-sitter compares the new tree with the old one as edited, so only what the edit changed comes back.
        let ranges = changedByteRanges(oldTree, newTree).map { $0.range }
        self.tree = newTree
        return .parsed(ranges)
    }

    /// Parses the text after `tree`, already edited, resuming the parse each time the parser's timeout stops it.
    /// - Returns: The new tree, or `nil` when the parse was cancelled or, if `budgeted`, ran out of time.
    private func parse(
        after tree: MutableTree,
        budgeted: Bool,
        readBlock: @escaping Parser.ReadBlock
    ) -> MutableTree? {
        let start = ContinuousClock.now
        var wasLongParse = false
        defer {
            if wasLongParse {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: TreeSitterClient.Constants.longParseFinished, object: nil)
                }
            }
        }

        // A timed out parse continues where it stopped when `parse` is called again over the same text.
        while true {
            if Task.isCancelled {
                parser.reset()
                return nil
            }
            if !wasLongParse, start.duration(to: .now) > TreeSitterClient.Constants.longParseTimeout {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: TreeSitterClient.Constants.longParse, object: nil)
                }
                wasLongParse = true
            }
            if let newTree = parser.parse(tree: tree, readBlock: readBlock) {
                return newTree
            }
            if budgeted {
                return nil
            }
        }
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
