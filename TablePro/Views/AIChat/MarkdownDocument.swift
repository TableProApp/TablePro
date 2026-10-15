//
//  MarkdownDocument.swift
//  TablePro
//

import Combine
import Foundation
import os

/// A reply's block structure, as Foundation's CommonMark and GitHub-flavored parser reads it.
internal struct MarkdownDocument: Equatable, Sendable {
    internal let blocks: [MarkdownBlock]
}

internal struct MarkdownBlock: Identifiable, Equatable, Sendable {
    /// The block's position among its siblings. A reply only grows at its end, so the blocks before the last keep
    /// their identity while it streams.
    internal let id: Int
    internal let kind: Kind

    internal enum Kind: Equatable, Sendable {
        case paragraph(AttributedString)
        case header(level: Int, text: AttributedString)
        case codeBlock(code: String, language: String?)
        case list(MarkdownList)
        case blockquote([MarkdownBlock])
        case table(MarkdownTable)
        case thematicBreak
    }
}

internal struct MarkdownList: Equatable, Sendable {
    /// The first item's number for an ordered list, nil for a bulleted one.
    internal let start: Int?
    internal let items: [MarkdownListItem]
}

internal struct MarkdownListItem: Identifiable, Equatable, Sendable {
    internal let id: Int
    internal let blocks: [MarkdownBlock]
}

internal struct MarkdownTable: Equatable, Sendable {
    internal let alignments: [MarkdownTableAlignment]
    internal let header: [AttributedString]
    internal let rows: [[AttributedString]]
}

internal enum MarkdownTableAlignment: Equatable, Sendable {
    case left
    case center
    case right
}

// MARK: - Parser

/// Turns markdown into a `MarkdownDocument` through `AttributedString(markdown:)` with full syntax, whose runs carry
/// each block's `PresentationIntent`. Runs of one block are contiguous and share the block's identity, so the tree is
/// rebuilt by walking every run's intent from the outermost component in.
internal enum MarkdownDocumentParser {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MarkdownDocumentParser")

    private static let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .full,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    internal static func parse(_ source: String) -> MarkdownDocument {
        guard !source.isEmpty else { return MarkdownDocument(blocks: []) }
        let parsed: AttributedString
        do {
            parsed = try AttributedString(markdown: source, options: options)
        } catch {
            logger.warning("Markdown did not parse, showing it as text: \(error.publicLogShape, privacy: .public)")
            return MarkdownDocument(blocks: [MarkdownBlock(id: 0, kind: .paragraph(AttributedString(source)))])
        }
        return MarkdownDocument(blocks: blocks(from: tree(of: parsed).children))
    }

    /// A reply still arriving ends mid-span: `**bold` with no closing pair yet reads as literal asterisks until it
    /// arrives. The last line is closed for the parse, unless it is code, where the characters are the content.
    internal static func parseStreaming(_ source: String) -> MarkdownDocument {
        let document = parse(source)
        guard !endsInCode(document.blocks) else { return document }
        let lastLineStart = source.lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
        let lastLine = String(source[lastLineStart...])
        let repaired = MarkdownInlineRepair.repairingDanglingSyntax(lastLine)
        guard repaired != lastLine else { return document }
        return parse(String(source[..<lastLineStart]) + repaired)
    }

    private static func endsInCode(_ blocks: [MarkdownBlock]) -> Bool {
        guard let last = blocks.last else { return false }
        switch last.kind {
        case .codeBlock:
            return true
        case .list(let list):
            return endsInCode(list.items.last?.blocks ?? [])
        case .blockquote(let children):
            return endsInCode(children)
        case .paragraph, .header, .table, .thematicBreak:
            return false
        }
    }

    // MARK: Tree

    private final class Node {
        let identity: Int
        /// Nil for raw HTML, which arrives with no block intent and reads as literal text.
        let kind: PresentationIntent.Kind?
        var children: [Node] = []
        var text = AttributedString()

        init(identity: Int, kind: PresentationIntent.Kind?) {
            self.identity = identity
            self.kind = kind
        }
    }

    private static func tree(of parsed: AttributedString) -> Node {
        let root = Node(identity: Int.min, kind: nil)
        var nextLooseIdentity = Int.min + 1
        for run in parsed.runs {
            var node = root
            if let intent = run.presentationIntent {
                for component in intent.components.reversed() {
                    if let last = node.children.last, last.identity == component.identity {
                        node = last
                    } else {
                        let child = Node(identity: component.identity, kind: component.kind)
                        node.children.append(child)
                        node = child
                    }
                }
            } else if let last = root.children.last, last.kind == nil {
                node = last
            } else {
                let loose = Node(identity: nextLooseIdentity, kind: nil)
                nextLooseIdentity += 1
                root.children.append(loose)
                node = loose
            }
            node.text.append(leafText(parsed[run.range], inline: run.inlinePresentationIntent))
        }
        return root
    }

    /// A soft break is the newline the author typed inside a paragraph. It stays a line break, as it always has in
    /// this chat, rather than the space CommonMark allows a renderer to draw.
    private static func leafText(
        _ slice: AttributedSubstring,
        inline: InlinePresentationIntent?
    ) -> AttributedString {
        if let inline, inline.contains(.softBreak) {
            return AttributedString("\n")
        }
        var text = AttributedString(slice)
        text.presentationIntent = nil
        return text
    }

    // MARK: Blocks

    private static func blocks(from nodes: [Node]) -> [MarkdownBlock] {
        nodes.enumerated().map { index, node in MarkdownBlock(id: index, kind: kind(of: node)) }
    }

    private static func kind(of node: Node) -> MarkdownBlock.Kind {
        guard let kind = node.kind else { return .paragraph(node.text) }
        switch kind {
        case .header(let level):
            return .header(level: level, text: node.text)
        case .codeBlock(let languageHint):
            var code = String(node.text.characters)
            if code.hasSuffix("\n") { code.removeLast() }
            let language = languageHint.flatMap { $0.isEmpty ? nil : $0 }
            return .codeBlock(code: code, language: language)
        case .orderedList, .unorderedList:
            return .list(list(from: node, isOrdered: kind == .orderedList))
        case .blockQuote:
            return .blockquote(blocks(from: node.children))
        case .table(let columns):
            return .table(table(from: node, columns: columns))
        case .thematicBreak:
            return .thematicBreak
        default:
            return .paragraph(node.text)
        }
    }

    private static func list(from node: Node, isOrdered: Bool) -> MarkdownList {
        var start: Int?
        if isOrdered {
            if case .listItem(let ordinal)? = node.children.first?.kind {
                start = ordinal
            } else {
                start = 1
            }
        }
        let items = node.children.enumerated().map { index, item in
            MarkdownListItem(id: index, blocks: blocks(from: item.children))
        }
        return MarkdownList(start: start, items: items)
    }

    /// An empty cell produces no run, so cells are placed by their column index rather than their order.
    private static func table(from node: Node, columns: [PresentationIntent.TableColumn]) -> MarkdownTable {
        let alignments: [MarkdownTableAlignment] = columns.map { column in
            switch column.alignment {
            case .center: .center
            case .right: .right
            default: .left
            }
        }
        func cells(of row: Node) -> [AttributedString] {
            var cells = Array(repeating: AttributedString(), count: alignments.count)
            for cell in row.children {
                guard case .tableCell(let column)? = cell.kind, cells.indices.contains(column) else { continue }
                cells[column] = cell.text
            }
            return cells
        }
        var header = Array(repeating: AttributedString(), count: alignments.count)
        var rows: [[AttributedString]] = []
        for row in node.children {
            if case .tableHeaderRow? = row.kind {
                header = cells(of: row)
            } else {
                rows.append(cells(of: row))
            }
        }
        return MarkdownTable(alignments: alignments, header: header, rows: rows)
    }
}

// MARK: - Settled documents

/// Parsed documents of settled text, keyed by the text. A transcript row is rebuilt each time it scrolls back into the
/// lazy stack, and the parse is the same every time.
internal final class MarkdownDocumentCache: @unchecked Sendable {
    internal static let shared = MarkdownDocumentCache()

    private final class Entry {
        let document: MarkdownDocument

        init(_ document: MarkdownDocument) {
            self.document = document
        }
    }

    /// `NSCache` is safe to use from any thread, which is what the unchecked conformance rests on.
    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 512
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()

    internal func cachedDocument(for source: String) -> MarkdownDocument? {
        cache.object(forKey: source as NSString)?.document
    }

    internal func document(for source: String) -> MarkdownDocument {
        if let cached = cachedDocument(for: source) {
            return cached
        }
        let document = MarkdownDocumentParser.parse(source)
        cache.setObject(Entry(document), forKey: source as NSString, cost: (source as NSString).length)
        return document
    }

    /// Parses a transcript's text before its rows are built, so scrolling back through a long conversation lays rows
    /// out without parsing them on the main actor.
    @concurrent
    internal func prewarm(_ sources: [String]) async {
        for source in sources where !Task.isCancelled {
            _ = document(for: source)
        }
    }
}

// MARK: - A row's document

/// The document one transcript row shows, kept current as its text grows and settles.
///
/// A parse is linear in the text, and a long reply would spend each 50 ms flush on the main actor parsing all of it,
/// then parse it once more when it finished. Every parse after the first runs away from the main actor, one at a
/// time, with the newest text winning; the row keeps showing what it has until the parse lands. The first parse runs
/// at once, because a row needs its height on the frame it appears, and for settled text it is usually a cache hit.
@MainActor
internal final class MarkdownDocumentModel: ObservableObject {
    @Published internal private(set) var document: MarkdownDocument
    /// Whether `document` is the parse of finished text. False while a reply streams, and until the parse of its final
    /// text lands.
    @Published internal private(set) var isSettled: Bool

    private struct Request: Equatable, Sendable {
        let source: String
        let isStreaming: Bool
    }

    private var latest: Request
    private var parsed: Request
    private var isParsing = false

    internal init(source: String, isStreaming: Bool) {
        let request = Request(source: source, isStreaming: isStreaming)
        document = Self.parseNow(request)
        isSettled = !isStreaming
        latest = request
        parsed = request
    }

    internal func update(source: String, isStreaming: Bool) {
        latest = Request(source: source, isStreaming: isStreaming)
        if !isStreaming, let cached = MarkdownDocumentCache.shared.cachedDocument(for: source) {
            parsed = latest
            show(cached, isSettled: true)
            return
        }
        guard !isParsing, latest != parsed else { return }
        parseLatest()
    }

    private func parseLatest() {
        isParsing = true
        let request = latest
        parsed = request
        Task { [weak self] in
            let document = await Self.parseAway(request)
            guard let self else { return }
            self.isParsing = false
            /// A cache hit for finished text can land while this parse runs; that newer document stays.
            if self.parsed == request {
                self.show(document, isSettled: !request.isStreaming)
            }
            if self.latest != self.parsed {
                self.parseLatest()
            }
        }
    }

    private func show(_ document: MarkdownDocument, isSettled: Bool) {
        if self.document != document {
            self.document = document
        }
        if self.isSettled != isSettled {
            self.isSettled = isSettled
        }
    }

    nonisolated private static func parseNow(_ request: Request) -> MarkdownDocument {
        request.isStreaming
            ? MarkdownDocumentParser.parseStreaming(request.source)
            : MarkdownDocumentCache.shared.document(for: request.source)
    }

    /// Settled text goes through the cache, so a finished reply is parsed once and its row finds it when rebuilt.
    @concurrent
    nonisolated private static func parseAway(_ request: Request) async -> MarkdownDocument {
        parseNow(request)
    }
}
