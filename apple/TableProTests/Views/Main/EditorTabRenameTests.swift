//
//  EditorTabRenameTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
private final class FocusTarget: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private struct RenameFixture {
    let strip: EditorTabStripView
    let window: NSWindow
    let focus: FocusTarget
    let recorder: EditorTabCommandRecorder

    func tab(_ index: Int) throws -> EditorTabItemView {
        try #require(strip.itemView(for: strip.items[index].id))
    }

    var renamed: [String] {
        recorder.renamed.map { $0.1 }
    }

    var renamedIds: [UUID] {
        recorder.renamed.map { $0.0 }
    }
}

// A titled window, unlike the strip tests' borderless one, so the field editor starts as it does on screen.
@MainActor
struct EditorTabRenameTests {
    private static let width: CGFloat = 652

    private func makeFixture(
        titles: [String] = ["Query 1", "Report", "Query 3"],
        canRename: Bool = true
    ) -> RenameFixture {
        let recorder = EditorTabCommandRecorder()
        let items = EditorTabItem.samples(titles: titles)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 120))
        let focus = FocusTarget(frame: NSRect(x: 0, y: 60, width: Self.width, height: 60))
        let strip = EditorTabStripView(
            frame: NSRect(x: 0, y: 0, width: Self.width, height: EditorTabStripLayout.bandHeight)
        )
        content.addSubview(focus)
        content.addSubview(strip)
        window.contentView = content
        strip.commands = .stub(
            recorder: recorder,
            canRename: canRename,
            renameSeed: { id in
                guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
                return EditorTabRenameSeed(text: items[index].title, placeholder: "Query \(index + 1)")
            }
        )
        strip.apply(items)
        strip.layoutSubtreeIfNeeded()
        window.makeFirstResponder(focus)
        return RenameFixture(strip: strip, window: window, focus: focus, recorder: recorder)
    }

    private func editor(of field: NSTextField?) throws -> NSTextView {
        try #require(field?.currentEditor() as? NSTextView)
    }

    private func type(_ text: String, in view: EditorTabItemView) throws {
        let editor = try editor(of: view.renameField)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private func press(_ command: Selector, in view: EditorTabItemView) throws {
        try editor(of: view.renameField).doCommand(by: command)
    }

    private func mouse(_ type: NSEvent.EventType, clickCount: Int, on view: EditorTabItemView) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: type == .leftMouseDown ? 1 : 0
        ))
    }

    private func pressMouse(on view: EditorTabItemView, clickCount: Int) throws {
        let event = try mouse(.leftMouseDown, clickCount: clickCount, on: view)
        view.mouseDown(with: event)
    }

    private func releaseMouse(on view: EditorTabItemView, clickCount: Int) throws {
        let event = try mouse(.leftMouseUp, clickCount: clickCount, on: view)
        view.mouseUp(with: event)
    }

    private func holdsFocus(_ view: EditorTabItemView, in window: NSWindow) -> Bool {
        guard let editor = window.firstResponder as? NSTextView else { return false }
        return editor.delegate === view.renameField
    }

    @Test("A double-click on a tab that can take a name opens its field on release, with the title selected")
    func doubleClickOpensTheFieldOnRelease() throws {
        let fixture = makeFixture()
        defer { fixture.window.orderOut(nil) }
        let view = try fixture.tab(1)

        try pressMouse(on: view, clickCount: 1)
        try releaseMouse(on: view, clickCount: 1)
        try pressMouse(on: view, clickCount: 2)
        #expect(!view.isRenaming)
        try releaseMouse(on: view, clickCount: 2)

        let field = try #require(view.renameField)
        #expect(view.isRenaming)
        #expect(field.stringValue == "Report")
        #expect(field.placeholderString == "Query 2")
        #expect(try editor(of: field).selectedRange() == NSRange(location: 0, length: 6))
        #expect(holdsFocus(view, in: fixture.window))
        #expect(view.titleField.isHidden)
        #expect(view.closeButton.isHidden)
        #expect(fixture.recorder.kept.isEmpty)
    }

    @Test("A tab that cannot take a name never opens the field")
    func ineligibleTabNeverOpensTheField() throws {
        let fixture = makeFixture(canRename: false)
        defer { fixture.window.orderOut(nil) }
        let view = try fixture.tab(1)

        fixture.strip.beginRename(view.item.id)

        #expect(!view.isRenaming)
        #expect(fixture.window.firstResponder === fixture.focus)
    }

    @Test("Return names the tab with what was typed, shows it at once and gives focus back")
    func returnCommitsTheTypedName() throws {
        let fixture = makeFixture()
        defer { fixture.window.orderOut(nil) }
        let view = try fixture.tab(1)
        fixture.strip.beginRename(view.item.id)

        try type("Monthly report", in: view)
        try press(#selector(NSResponder.insertNewline(_:)), in: view)

        #expect(fixture.renamedIds == [view.item.id])
        #expect(fixture.renamed == ["Monthly report"])
        #expect(!view.isRenaming)
        #expect(!view.titleField.isHidden)
        #expect(view.titleField.stringValue == "Monthly report")
        #expect(fixture.window.firstResponder === fixture.focus)
    }

    @Test("Return on an untouched name changes nothing")
    func returnWithoutAnEditCommitsNothing() throws {
        let fixture = makeFixture()
        defer { fixture.window.orderOut(nil) }
        let view = try fixture.tab(0)
        fixture.strip.beginRename(view.item.id)

        try press(#selector(NSResponder.insertNewline(_:)), in: view)

        #expect(fixture.recorder.renamed.isEmpty)
        #expect(!view.isRenaming)
        #expect(view.titleField.stringValue == "Query 1")
        #expect(fixture.window.firstResponder === fixture.focus)
    }

    @Test("Retyping the automatic name names the tab with it")
    func retypedNameCounts() throws {
        let fixture = makeFixture()
        defer { fixture.window.orderOut(nil) }
        let view = try fixture.tab(0)
        fixture.strip.beginRename(view.item.id)

        try type("Query 1", in: view)
        try press(#selector(NSResponder.insertNewline(_:)), in: view)

        #expect(fixture.renamed == ["Query 1"])
    }

    @Test("Escape drops what was typed and gives focus back")
    func escapeCancels() throws {
        let fixture = makeFixture()
        defer { fixture.window.orderOut(nil) }
        let view = try fixture.tab(1)
        fixture.strip.beginRename(view.item.id)

        try type("Monthly", in: view)
        try press(#selector(NSResponder.cancelOperation(_:)), in: view)

        #expect(fixture.recorder.renamed.isEmpty)
        #expect(!view.isRenaming)
        #expect(view.titleField.stringValue == "Report")
        #expect(fixture.window.firstResponder === fixture.focus)
    }

    @Test("An emptied field hands over empty text, and the tab shows its automatic name")
    func emptiedFieldReturnsToTheAutomaticName() throws {
        let fixture = makeFixture()
        defer { fixture.window.orderOut(nil) }
        let view = try fixture.tab(1)
        fixture.strip.beginRename(view.item.id)

        let editor = try editor(of: view.renameField)
        editor.selectAll(nil)
        editor.deleteBackward(nil)
        try press(#selector(NSResponder.insertNewline(_:)), in: view)

        #expect(fixture.renamed == [""])
        #expect(view.titleField.stringValue == "Query 2")
    }

    @Test("Tab commits the way Return does")
    func tabKeyCommits() throws {
        let fixture = makeFixture()
        defer { fixture.window.orderOut(nil) }
        let view = try fixture.tab(1)
        fixture.strip.beginRename(view.item.id)

        try type("Monthly", in: view)
        try press(#selector(NSResponder.insertTab(_:)), in: view)

        #expect(fixture.renamed == ["Monthly"])
        #expect(!view.isRenaming)
        #expect(fixture.window.firstResponder === fixture.focus)
    }

    @Test("A refresh during the edit leaves the field and what is typed in it alone")
    func refreshKeepsTheEdit() throws {
        let fixture = makeFixture()
        defer { fixture.window.orderOut(nil) }
        let view = try fixture.tab(1)
        let id = view.item.id
        fixture.strip.beginRename(id)
        try type("Monthly", in: view)

        fixture.strip.apply(fixture.strip.items.map { item in
            EditorTabItem.sample(
                id: item.id,
                title: item.id == id ? "Renamed elsewhere" : item.title,
                isSelected: item.isSelected,
                status: item.id == id ? .running : .idle,
                position: item.position,
                count: item.count
            )
        })
        fixture.strip.layoutSubtreeIfNeeded()

        #expect(fixture.strip.itemView(for: id) === view)
        #expect(view.isRenaming)
        #expect(try editor(of: view.renameField).string == "Monthly")
        #expect(view.titleField.isHidden)
        #expect(holdsFocus(view, in: fixture.window))
    }

    @Test("A tab that leaves the strip mid-edit hands over what was typed and gives focus back")
    func removedTabEndsTheEdit() throws {
        let fixture = makeFixture()
        defer { fixture.window.orderOut(nil) }
        let view = try fixture.tab(1)
        let id = view.item.id
        fixture.strip.beginRename(id)
        try type("Monthly", in: view)

        fixture.strip.apply(fixture.strip.items.filter { $0.id != id })

        #expect(fixture.strip.itemView(for: id) == nil)
        #expect(fixture.renamedIds == [id])
        #expect(fixture.renamed == ["Monthly"])
        #expect(fixture.window.firstResponder === fixture.focus)
    }

    @Test("Clicking another tab commits the edit before selecting it")
    func clickOnAnotherTabCommits() throws {
        let fixture = makeFixture()
        defer { fixture.window.orderOut(nil) }
        let view = try fixture.tab(1)
        let other = fixture.strip.items[2].id
        fixture.strip.beginRename(view.item.id)
        try type("Monthly", in: view)

        fixture.strip.activate(other, click: EditorTabClick(clickCount: 1, hasModifiers: false))

        #expect(fixture.renamedIds == [view.item.id])
        #expect(fixture.recorder.activated == [other])
        #expect(!view.isRenaming)
    }

    @Test("Starting a rename on another tab commits the first")
    func secondRenameCommitsTheFirst() throws {
        let fixture = makeFixture()
        defer { fixture.window.orderOut(nil) }
        let first = try fixture.tab(0)
        let second = try fixture.tab(1)
        fixture.strip.beginRename(first.item.id)
        try type("Scratch", in: first)

        fixture.strip.beginRename(second.item.id)

        #expect(fixture.renamedIds == [first.item.id])
        #expect(!first.isRenaming)
        #expect(second.isRenaming)
        #expect(holdsFocus(second, in: fixture.window))
    }

    @Test("The window resigning key commits the edit")
    func resigningKeyCommits() async throws {
        let fixture = makeFixture()
        defer { fixture.window.orderOut(nil) }
        let view = try fixture.tab(1)
        fixture.strip.beginRename(view.item.id)
        try type("Monthly", in: view)

        fixture.window.resignKey()
        try await waitUntil { !view.isRenaming }

        #expect(fixture.renamed == ["Monthly"])
    }

    @Test("A strip taken out of its window commits the edit")
    func stripLeavingTheWindowCommits() throws {
        let fixture = makeFixture()
        defer { fixture.window.orderOut(nil) }
        let view = try fixture.tab(1)
        fixture.strip.beginRename(view.item.id)
        try type("Monthly", in: view)

        fixture.strip.removeFromSuperview()

        // AppKit resigns the field before the strip hears it is leaving, so where focus goes is AppKit's.
        #expect(fixture.renamed == ["Monthly"])
        #expect(!view.isRenaming)
        #expect(!holdsFocus(view, in: fixture.window))
    }

    @Test("Scrolling the tab into the strip's edge commits the edit")
    func squeezedTabCommits() throws {
        let fixture = makeFixture(titles: (1 ... 14).map { "Query \($0)" })
        defer { fixture.window.orderOut(nil) }
        let view = try fixture.tab(0)
        fixture.strip.beginRename(view.item.id)
        #expect(view.isRenaming)
        try type("Scratch", in: view)

        let clip = fixture.strip.scrollView.contentView
        clip.setBoundsOrigin(NSPoint(x: fixture.strip.run.maximumOffset, y: clip.bounds.minY))

        #expect(view.frame.width < EditorTabStripLayout.minimumContentWidth)
        #expect(!view.isRenaming)
        #expect(fixture.renamed == ["Scratch"])
    }

    @Test("A press in the field reaches the field, and one beside it the tab")
    func pressInTheFieldReachesIt() throws {
        let fixture = makeFixture()
        defer { fixture.window.orderOut(nil) }
        let view = try fixture.tab(1)
        fixture.strip.beginRename(view.item.id)
        let field = try #require(view.renameField)

        let inside = view.convert(NSPoint(x: field.frame.midX, y: field.frame.midY), to: view.superview)
        let hit = try #require(view.hitTest(inside))
        #expect(hit === field || hit.isDescendant(of: field))

        let beside = view.convert(NSPoint(x: view.bounds.minX + 2, y: view.bounds.midY), to: view.superview)
        #expect(view.hitTest(beside) === view)
        #expect(field.mouseDownCanMoveWindow == false)
    }

    @Test("The field stays inside the tab and is named for assistive technology")
    func fieldGeometryAndName() throws {
        let fixture = makeFixture()
        defer { fixture.window.orderOut(nil) }
        let view = try fixture.tab(1)
        fixture.strip.beginRename(view.item.id)
        let field = try #require(view.renameField)

        #expect(view.bounds.contains(field.frame))
        #expect(field.frame.width > 0)
        let cell = try #require(field.cell)
        #expect(cell.isAccessibilityElement())
        #expect(cell.accessibilityLabel() == String(localized: "Tab Name"))
        #expect(cell.accessibilityIdentifier() == "editor-tab-rename-field")
    }
}
