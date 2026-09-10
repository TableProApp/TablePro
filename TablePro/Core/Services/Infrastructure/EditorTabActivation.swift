//
//  EditorTabActivation.swift
//  TablePro
//

import AppKit
import Foundation

/// What a click on a tab in the editor tab strip is asking for.
internal enum EditorTabActivation: Equatable {
    case select
    /// Select, then keep the tab: the double-click that turns a preview tab permanent.
    case selectAndKeep
}

/// One click on a tab, reduced to the two things that decide what it means.
///
/// `NSEvent.clickCount` is only valid on a mouse-down or mouse-up and raises for anything else,
/// so the type is checked here rather than at the call site. A tab's button also answers the
/// keyboard and VoiceOver, and neither leaves a mouse event current: both resolve to nil, which
/// the resolver reads as a plain selection. Keeping a tab from the keyboard goes through the
/// "Keep Open" command instead.
internal struct EditorTabClick: Equatable {
    internal let clickCount: Int
    internal let hasModifiers: Bool

    internal init(clickCount: Int, hasModifiers: Bool) {
        self.clickCount = clickCount
        self.hasModifiers = hasModifiers
    }

    internal init?(event: NSEvent?) {
        guard let event, Self.carriesClickCount(event.type) else { return nil }
        clickCount = event.clickCount
        hasModifiers = !event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
            .isEmpty
    }

    /// Only the primary button. A control-click is the context-menu gesture and arrives as a left
    /// mouse-down with a modifier, which `hasModifiers` then rejects.
    private static func carriesClickCount(_ type: NSEvent.EventType) -> Bool {
        type == .leftMouseDown || type == .leftMouseUp
    }
}

/// Resolves a click on a tab into what it means, without reference to AppKit or to the strip.
///
/// The second click has to land on the tab the first one activated. Two clicks close enough in
/// time and space arrive as one click of count two whichever view each of them hit, and tabs sit
/// flush against each other, so a pair straddling a boundary would otherwise keep a tab the user
/// only meant to select. `NSTableView` has the same exposure and lives with it, because its
/// double-click opens the row the second click hit and a single click would have led there
/// anyway; here it would change a tab's state without being asked.
///
/// Any count above one keeps the tab, rather than two exactly. That same coalescing carries the
/// count on past two, so a double-click following a nearby click arrives as counts two and three:
/// the two is refused by the guard above, and a strict `== 2` would refuse the three as well,
/// leaving a genuine double-click doing nothing. Keeping is idempotent and one way, so acting on
/// the three costs nothing.
internal enum EditorTabActivationResolver {
    internal static func resolve(
        click: EditorTabClick?,
        tabId: UUID,
        lastActivatedTabId: UUID?
    ) -> EditorTabActivation {
        guard let click, click.clickCount >= 2, !click.hasModifiers else { return .select }
        return lastActivatedTabId == tabId ? .selectAndKeep : .select
    }
}
