//
//  EditorDocumentCache.swift
//  TableProEditorKit
//

import AppKit
import TableProTextEngine

/// A document the editor showed and will show again: its text storage with the styles on it, the lines it was laid
/// out in and its committed parse. Showing it again swaps these back in instead of rebuilding them.
@MainActor
final class EditorDocument {
    /// What one UTF-16 unit costs to keep: the storage's characters and attribute runs, the parse's text snapshot and,
    /// most of it, the syntax tree. `phys_footprint` grew 59 MB for each 1,000,000-unit SQL script kept.
    static let bytesPerUnit = 64
    /// What one line costs in the line storage, before it is typeset.
    static let bytesPerLine = 96

    let storage: NSTextStorage
    let lines: TextLayoutManager.DetachedLines
    let parse: TreeSitterClient.ParkedParse?
    private let typingAttributes: NSDictionary
    let bytes: Int

    init(
        storage: NSTextStorage,
        lines: TextLayoutManager.DetachedLines,
        parse: TreeSitterClient.ParkedParse?,
        typingAttributes: [NSAttributedString.Key: Any]
    ) {
        self.storage = storage
        self.lines = lines
        self.parse = parse
        self.typingAttributes = typingAttributes as NSDictionary
        self.bytes = storage.length * Self.bytesPerUnit + lines.count * Self.bytesPerLine
    }

    /// Whether this document still is `text` as the editor would draw it now. A tab whose text changed while it was
    /// hidden, or a font or theme that changed since, needs the document built again.
    func matches(_ text: String, typingAttributes: [NSAttributedString.Key: Any]) -> Bool {
        let text = text as NSString
        return storage.length == text.length
            && self.typingAttributes.isEqual(to: typingAttributes)
            && storage.mutableString.isEqual(to: text as String)
    }
}

/// The documents an editor keeps for the tabs it does not show, least recently shown dropped first once they hold more
/// than ``limit`` bytes. A dropped document costs only speed: the tab's text is still with its owner, and showing it
/// builds the document again.
@MainActor
public final class EditorDocumentCache {
    /// The default ``limit``: the two most recent tabs of a 1.9M-character script, or hundreds of everyday queries.
    public static let defaultLimit = 256 * 1_024 * 1_024

    /// The most the kept documents may hold, in bytes.
    public var limit: Int {
        didSet { evict() }
    }

    /// What the kept documents hold now, in bytes.
    public private(set) var bytes = 0

    private var entries: [AnyHashable: EditorDocument] = [:]
    // Least recently shown first.
    private var order: [AnyHashable] = []

    public init(limit: Int = EditorDocumentCache.defaultLimit) {
        self.limit = limit
    }

    /// The number of documents kept.
    public var count: Int { entries.count }

    /// Whether no document is kept.
    public var isEmpty: Bool { entries.isEmpty }

    func store(_ document: EditorDocument, for id: AnyHashable) {
        forget(id)
        guard document.bytes <= limit else { return }
        entries[id] = document
        order.append(id)
        bytes += document.bytes
        evict()
    }

    func take(_ id: AnyHashable) -> EditorDocument? {
        guard let document = entries.removeValue(forKey: id) else { return nil }
        order.removeAll { $0 == id }
        bytes -= document.bytes
        return document
    }

    /// Drops the document kept for `id`, as when its tab closes.
    public func forget(_ id: AnyHashable) {
        _ = take(id)
    }

    /// Drops every document except those kept for `ids`.
    public func forgetAll(except ids: Set<AnyHashable>) {
        for id in order where !ids.contains(id) {
            forget(id)
        }
    }

    private func evict() {
        while bytes > limit, let oldest = order.first {
            forget(oldest)
        }
    }
}
