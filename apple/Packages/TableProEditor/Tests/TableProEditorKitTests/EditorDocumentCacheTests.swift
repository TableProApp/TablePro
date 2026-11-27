//
//  EditorDocumentCacheTests.swift
//  TableProEditorKitTests
//
//  One editor shows every query tab. A tab shown before comes back with its own storage, lines and parse instead of
//  a rebuild, as long as it still holds the same text.
//

import AppKit
import SwiftUI
@testable import TableProEditorKit
import TableProGrammars
import TableProTestSupport
import TableProTextEngine
import Testing

@MainActor
private final class TabOwner {
    var text: String
    var documentID: AnyHashable?

    init(text: String, documentID: AnyHashable?) {
        self.text = text
        self.documentID = documentID
    }

    func editor(_ state: Binding<SourceEditorState>) -> SourceEditor {
        SourceEditor(
            Binding(get: { self.text }, set: { self.text = $0 }),
            language: .sql,
            configuration: Mock.config(),
            state: state,
            documentID: documentID
        )
    }
}

@MainActor
struct EditorDocumentCacheTests {
    private static let first = "SELECT id, name FROM users WHERE id = 1;\n"
    private static let second = "UPDATE orders SET total = 2 WHERE id = 3;\n"
    private static let third = "DELETE FROM carts WHERE id = 4;\n"

    private func mount(_ owner: TabOwner, cache: EditorDocumentCache) -> (SourceEditorHost, NSWindow) {
        let host = SourceEditorHost { owner.editor($0) }
        host.controller.documentCache = cache
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host.controller.view
        window.contentView?.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func show(_ text: String, as id: AnyHashable, owner: TabOwner, host: SourceEditorHost) {
        owner.text = text
        owner.documentID = id
        host.update { owner.editor($0) }
    }

    private func parsed(_ host: SourceEditorHost) async throws -> TreeSitterState {
        let client = try #require(host.controller.treeSitterClient)
        try await waitUntil(timeout: .seconds(30)) { client.state != nil }
        return try #require(client.state)
    }

    @Test("A tab shown again gets back its storage, its lines and its parse")
    func shownTabIsReused() async throws {
        let cache = EditorDocumentCache()
        let owner = TabOwner(text: Self.first, documentID: AnyHashable(1))
        let (host, window) = mount(owner, cache: cache)
        defer { window.orderOut(nil) }
        let firstState = try await parsed(host)
        let firstStorage = try #require(host.controller.textView.textStorage)
        let firstLines = host.controller.textView.layoutManager.lineStorage

        show(Self.second, as: AnyHashable(2), owner: owner, host: host)
        _ = try await parsed(host)
        #expect(host.controller.textView.string == Self.second)
        #expect(cache.count == 1)

        show(Self.first, as: AnyHashable(1), owner: owner, host: host)

        #expect(host.controller.textView.textStorage === firstStorage)
        #expect(host.controller.textView.layoutManager.lineStorage === firstLines)
        #expect(host.controller.treeSitterClient?.state === firstState, "The tab was parsed again")
        #expect(host.controller.textView.string == Self.first)
        let client = try #require(host.controller.treeSitterClient)
        let range = NSRange(location: 0, length: (Self.first as NSString).length)
        #expect(!client.queryHighlightsForRange(range: range).isEmpty)
        #expect(cache.count == 1)
    }

    @Test("A tab shown again with other text is built from that text")
    func changedTabIsRebuilt() async throws {
        let cache = EditorDocumentCache()
        let owner = TabOwner(text: Self.first, documentID: AnyHashable(1))
        let (host, window) = mount(owner, cache: cache)
        defer { window.orderOut(nil) }
        _ = try await parsed(host)
        let firstStorage = try #require(host.controller.textView.textStorage)

        show(Self.second, as: AnyHashable(2), owner: owner, host: host)
        show(Self.third, as: AnyHashable(1), owner: owner, host: host)

        #expect(host.controller.textView.textStorage !== firstStorage)
        #expect(host.controller.textView.string == Self.third)
        let state = try await parsed(host)
        #expect(state.layers.first?.tree?.rootNode?.byteRange.upperBound == UInt32((Self.third as NSString).length * 2))
    }

    @Test("Over the limit, the least recently shown tab is dropped first")
    func leastRecentlyShownIsDropped() async throws {
        let cache = EditorDocumentCache()
        let owner = TabOwner(text: Self.first, documentID: AnyHashable(1))
        let (host, window) = mount(owner, cache: cache)
        defer { window.orderOut(nil) }
        let firstStorage = try #require(host.controller.textView.textStorage)

        show(Self.second, as: AnyHashable(2), owner: owner, host: host)
        let secondStorage = try #require(host.controller.textView.textStorage)
        // Room for the second tab's document, a character longer than the first's, but not for both.
        cache.limit = cache.bytes + EditorDocument.bytesPerUnit * 2
        show(Self.third, as: AnyHashable(3), owner: owner, host: host)

        #expect(cache.count == 1)
        #expect(cache.bytes <= cache.limit)
        show(Self.second, as: AnyHashable(2), owner: owner, host: host)
        #expect(host.controller.textView.textStorage === secondStorage)
        show(Self.first, as: AnyHashable(1), owner: owner, host: host)
        #expect(host.controller.textView.textStorage !== firstStorage)
    }

    @Test("A closed tab's document is dropped")
    func forgottenTabIsDropped() {
        let cache = EditorDocumentCache()
        let owner = TabOwner(text: Self.first, documentID: AnyHashable(1))
        let (host, window) = mount(owner, cache: cache)
        defer { window.orderOut(nil) }

        show(Self.second, as: AnyHashable(2), owner: owner, host: host)
        show(Self.third, as: AnyHashable(3), owner: owner, host: host)
        #expect(cache.count == 2)

        cache.forget(AnyHashable(1))
        #expect(cache.count == 1)
        cache.forgetAll(except: [AnyHashable(3)])
        #expect(cache.isEmpty)
        #expect(cache.bytes == 0)
    }

    @Test("A document drawn with other typing attributes, as after a font change, is not reused")
    func typingAttributesMustMatch() {
        let textView = TextView(string: Self.first)
        let document = EditorDocument(
            storage: textView.textStorage,
            lines: textView.layoutManager.detachLines(),
            parse: nil,
            typingAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
        )

        #expect(document.matches(Self.first, typingAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        ]))
        #expect(!document.matches(Self.first, typingAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        ]))
        #expect(!document.matches(Self.second, typingAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        ]))
    }
}
