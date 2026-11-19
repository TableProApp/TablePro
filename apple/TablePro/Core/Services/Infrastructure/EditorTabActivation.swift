//
//  EditorTabActivation.swift
//  TablePro
//

import AppKit
import Foundation

internal enum EditorTabActivation: Equatable {
    case select
    // The double-click that keeps a preview tab, and names a tab that can take a name instead.
    case selectAndKeep
}

// The keyboard and VoiceOver leave no mouse event, so both read as a plain selection; "Keep Open" keeps a tab from the keyboard.
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

    // `clickCount` raises on any other event type, and a control-click arrives here with a modifier that `hasModifiers` rejects.
    private static func carriesClickCount(_ type: NSEvent.EventType) -> Bool {
        type == .leftMouseDown || type == .leftMouseUp
    }
}

// Two clicks straddling a tab boundary coalesce into a count of two, so the second has to land on the tab the first activated.
// Any count above one acts, since a double-click after a nearby click arrives as two and three, and acting again changes nothing.
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
