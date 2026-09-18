//
//  ResultVisibility.swift
//  TablePro
//

import Foundation

/// Whether the user can already see the result of an operation that just finished. Pure so the
/// rule is testable without AppKit; `ResultVisibilityResolver` is the only thing that reads the
/// real window state.
internal struct ResultVisibility: Equatable, Sendable {
    internal var appIsActive: Bool
    internal var ownerWindowIsVisible: Bool
    internal var ownerIsSelectedInWindow: Bool

    internal init(appIsActive: Bool, ownerWindowIsVisible: Bool, ownerIsSelectedInWindow: Bool) {
        self.appIsActive = appIsActive
        self.ownerWindowIsVisible = ownerWindowIsVisible
        self.ownerIsSelectedInWindow = ownerIsSelectedInWindow
    }

    /// All three, because any one of them being false means the result landed somewhere the user
    /// is not looking. This is the whole feature: every client that skipped it, and DBeaver and
    /// Sequel Ace both did, ships a notification users mute at the OS level instead of using.
    internal var resultIsOnScreen: Bool {
        appIsActive && ownerWindowIsVisible && ownerIsSelectedInWindow
    }

    internal static let onScreen = ResultVisibility(
        appIsActive: true,
        ownerWindowIsVisible: true,
        ownerIsSelectedInWindow: true
    )

    internal static let offScreen = ResultVisibility(
        appIsActive: false,
        ownerWindowIsVisible: false,
        ownerIsSelectedInWindow: false
    )
}
