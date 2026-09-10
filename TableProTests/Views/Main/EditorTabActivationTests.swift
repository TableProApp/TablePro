//
//  EditorTabActivationTests.swift
//  TableProTests
//

import AppKit
import Foundation
import Testing

@testable import TablePro

@Suite("Editor Tab Activation")
struct EditorTabActivationTests {
    private static func resolve(
        clickCount: Int,
        hasModifiers: Bool = false,
        sameTab: Bool = true
    ) -> EditorTabActivation {
        let tabId = UUID()
        return EditorTabActivationResolver.resolve(
            click: EditorTabClick(clickCount: clickCount, hasModifiers: hasModifiers),
            tabId: tabId,
            lastActivatedTabId: sameTab ? tabId : UUID()
        )
    }

    @Test("A single click selects")
    func singleClickSelects() {
        #expect(Self.resolve(clickCount: 1) == .select)
    }

    @Test("A second click on the same tab keeps it open")
    func doubleClickKeepsTheTab() {
        #expect(Self.resolve(clickCount: 2) == .selectAndKeep)
    }

    /// Two clicks close enough in time and space arrive as one click of count two whichever view
    /// each of them hit, and tabs sit flush against each other. Without this the pair would keep a
    /// tab the user only meant to select.
    @Test("A second click on a different tab only selects")
    func doubleClickAcrossTabsOnlySelects() {
        #expect(Self.resolve(clickCount: 2, sameTab: false) == .select)
    }

    @Test("The first click of a session only selects")
    func firstClickOfASessionSelects() {
        #expect(
            EditorTabActivationResolver.resolve(
                click: EditorTabClick(clickCount: 2, hasModifiers: false),
                tabId: UUID(),
                lastActivatedTabId: nil
            ) == .select
        )
    }

    @Test("A modified click never keeps the tab")
    func modifiedClickOnlySelects() {
        #expect(Self.resolve(clickCount: 2, hasModifiers: true) == .select)
    }

    /// A double-click that follows a nearby click arrives as counts two and three, so refusing
    /// the three would leave a genuine double-click doing nothing. Keeping is idempotent, so
    /// acting on it costs nothing.
    @Test("A count above two still keeps the tab")
    func tripleClickStillKeepsTheTab() {
        #expect(Self.resolve(clickCount: 3) == .selectAndKeep)
    }

    @Test("A count above two on a different tab still only selects")
    func tripleClickAcrossTabsOnlySelects() {
        #expect(Self.resolve(clickCount: 3, sameTab: false) == .select)
    }

    /// The keyboard and VoiceOver both activate the tab's button with no mouse event current.
    @Test("An activation with no click behind it only selects")
    func activationWithoutAClickSelects() {
        #expect(
            EditorTabActivationResolver.resolve(click: nil, tabId: UUID(), lastActivatedTabId: UUID()) == .select
        )
    }

    // MARK: - Reading the click off an NSEvent

    private static func mouseEvent(_ type: NSEvent.EventType, clickCount: Int, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 0
        )
    }

    @Test("A left mouse-up carries its click count")
    func leftMouseUpCarriesClickCount() throws {
        let event = try #require(Self.mouseEvent(.leftMouseUp, clickCount: 2))
        let click = try #require(EditorTabClick(event: event))
        #expect(click.clickCount == 2)
        #expect(click.hasModifiers == false)
    }

    @Test("A control-click reads as modified, so it never keeps the tab")
    func controlClickReadsAsModified() throws {
        let event = try #require(Self.mouseEvent(.leftMouseDown, clickCount: 2, modifiers: .control))
        let click = try #require(EditorTabClick(event: event))
        #expect(click.hasModifiers)
    }

    /// Caps lock says nothing about intent, and leaving it out stops a stuck key disabling the
    /// gesture outright.
    @Test("Caps lock does not count as a modifier")
    func capsLockIsNotAModifier() throws {
        let event = try #require(Self.mouseEvent(.leftMouseUp, clickCount: 2, modifiers: .capsLock))
        let click = try #require(EditorTabClick(event: event))
        #expect(click.hasModifiers == false)
    }

    /// `NSEvent.clickCount` raises for anything that is not a mouse-down or mouse-up, so the type
    /// has to be checked before it is read.
    @Test("A right-click is not a tab activation")
    func rightClickIsNotAnActivation() throws {
        let event = try #require(Self.mouseEvent(.rightMouseDown, clickCount: 2))
        #expect(EditorTabClick(event: event) == nil)
    }

    @Test("No current event is not a click")
    func noEventIsNotAClick() {
        #expect(EditorTabClick(event: nil) == nil)
    }
}
