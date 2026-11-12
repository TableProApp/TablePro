//
//  SourceEditorUndoHistoryTests.swift
//  TableProEditorKitTests
//
//  An owner that names its document gets text it sets in that document as an edit Undo takes back, and a new
//  document as a new history. A history saved with a document comes back only onto the same text.
//

import AppKit
import SwiftUI
@testable import TableProEditorKit
import TableProTextEngine
import Testing

@MainActor
private final class DocumentOwner {
    var text: String
    var documentID: AnyHashable?

    init(text: String, documentID: AnyHashable?) {
        self.text = text
        self.documentID = documentID
    }

    func editor(_ state: Binding<SourceEditorState>) -> SourceEditor {
        SourceEditor(
            Binding(get: { self.text }, set: { self.text = $0 }),
            language: .default,
            configuration: Mock.config(),
            state: state,
            highlightProviders: [],
            documentID: documentID
        )
    }
}

@MainActor
struct SourceEditorUndoHistoryTests {
    private static let query = AnyHashable("query")
    private static let other = AnyHashable("other")

    private func mount(_ owner: DocumentOwner) -> (SourceEditorHost, NSWindow) {
        let host = SourceEditorHost { owner.editor($0) }
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

    private func show(_ text: String, as documentID: AnyHashable?, owner: DocumentOwner, host: SourceEditorHost) {
        owner.text = text
        owner.documentID = documentID
        host.update { owner.editor($0) }
    }

    // The owner's update pass after the editor writes the text back, as SwiftUI runs it.
    private func type(_ string: String, at location: Int, owner: DocumentOwner, host: SourceEditorHost) {
        host.controller.textView.replaceCharacters(in: NSRange(location: location, length: 0), with: string)
        host.update { owner.editor($0) }
    }

    private func selection(_ host: SourceEditorHost) -> [NSRange] {
        host.controller.textView.selectionManager.textSelections.map(\.range)
    }

    @Test("Text the owner sets in the same document is one step Undo takes back")
    func sameDocumentChangeIsUndoable() {
        let owner = DocumentOwner(text: "SELECT 1", documentID: Self.query)
        let (host, window) = mount(owner)
        defer { window.orderOut(nil) }

        show("", as: Self.query, owner: owner, host: host)
        #expect(host.controller.textView.string == "")

        host.controller.textView.undoManager?.undo()
        #expect(host.controller.textView.string == "SELECT 1")
        #expect(owner.text == "SELECT 1")
    }

    @Test("Text set in the same document skips the typing filters")
    func sameDocumentChangeIsUnfiltered() {
        let owner = DocumentOwner(text: "SELECT 1", documentID: Self.query)
        let (host, window) = mount(owner)
        defer { window.orderOut(nil) }

        show("(", as: Self.query, owner: owner, host: host)

        #expect(host.controller.textView.string == "(")
    }

    @Test("Text set in the same document leaves the caret where it was")
    func sameDocumentChangeKeepsTheCaret() {
        let owner = DocumentOwner(text: "SELECT 1", documentID: Self.query)
        let (host, window) = mount(owner)
        defer { window.orderOut(nil) }
        host.controller.setCursorPositions([CursorPosition(range: NSRange(location: 3, length: 0))])

        show("SELECT 2", as: Self.query, owner: owner, host: host)

        #expect(host.controller.textView.string == "SELECT 2")
        #expect(selection(host) == [NSRange(location: 3, length: 0)])
    }

    @Test("Another document starts a new history")
    func newDocumentStartsANewHistory() {
        let owner = DocumentOwner(text: "SELECT 1", documentID: Self.query)
        let (host, window) = mount(owner)
        defer { window.orderOut(nil) }
        type("0", at: 8, owner: owner, host: host)
        #expect(host.controller.textView.undoManager?.canUndo == true)

        show("SELECT 2", as: Self.other, owner: owner, host: host)

        #expect(host.controller.textView.string == "SELECT 2")
        #expect(host.controller.textView.undoManager?.canUndo == false)
    }

    @Test("Another document with the same text still starts a new history")
    func newDocumentWithTheSameTextStartsANewHistory() {
        let owner = DocumentOwner(text: "SELECT 1", documentID: Self.query)
        let (host, window) = mount(owner)
        defer { window.orderOut(nil) }
        type("0", at: 8, owner: owner, host: host)

        show("SELECT 10", as: Self.other, owner: owner, host: host)

        #expect(host.controller.textView.undoManager?.canUndo == false)
    }

    @Test("An owner that names no document gets a new history on every change, as before")
    func unnamedDocumentKeepsReplacingTheText() {
        let owner = DocumentOwner(text: "SELECT 1", documentID: nil)
        let (host, window) = mount(owner)
        defer { window.orderOut(nil) }
        type("0", at: 8, owner: owner, host: host)

        show("SELECT 2", as: nil, owner: owner, host: host)

        #expect(host.controller.textView.string == "SELECT 2")
        #expect(host.controller.textView.undoManager?.canUndo == false)
    }

    @Test("A history saved with its document comes back with it")
    func savedHistoryComesBackWithItsDocument() throws {
        let owner = DocumentOwner(text: "SELECT 1", documentID: Self.query)
        let (host, window) = mount(owner)
        defer { window.orderOut(nil) }
        type("0", at: 8, owner: owner, host: host)

        let saved = try #require(host.controller.takeUndoHistory())
        #expect(host.controller.textView.undoManager?.canUndo == false)
        #expect(host.controller.takeUndoHistory() == nil)
        show("SELECT 2", as: Self.other, owner: owner, host: host)
        show("SELECT 10", as: Self.query, owner: owner, host: host)

        #expect(host.controller.restoreUndoHistory(saved))
        host.controller.textView.undoManager?.undo()
        #expect(host.controller.textView.string == "SELECT 1")
    }

    @Test("A saved history is not put back on text that changed")
    func savedHistoryIsDroppedForChangedText() throws {
        let owner = DocumentOwner(text: "SELECT 1", documentID: Self.query)
        let (host, window) = mount(owner)
        defer { window.orderOut(nil) }
        type("0", at: 8, owner: owner, host: host)

        let saved = try #require(host.controller.takeUndoHistory())
        show("SELECT 2", as: Self.other, owner: owner, host: host)
        show("SELECT 99", as: Self.query, owner: owner, host: host)

        #expect(!host.controller.restoreUndoHistory(saved))
        #expect(host.controller.textView.undoManager?.canUndo == false)
    }
}
