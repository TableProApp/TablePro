//
//  CommandActionsRegistry.swift
//  TablePro
//
//  Singleton that tracks the `MainContentCommandActions` of the currently
//  key main window. Exists because `@FocusedValue(\.commandActions)` is not
//  reliable in our NSHostingView-hosted setup: each `NSHostingController`
//  (toolbar items + main content) is its own SwiftUI scene context, and
//  focus-scene-value propagation breaks once a toolbar Button takes scene
//  focus. The registry is updated on `windowDidBecomeKey` from
//  `TabWindowController`, then read by `AppMenuCommands` as a fallback when
//  `@FocusedValue` returns nil — so menu shortcuts (Cmd+T, Cmd+1...9, etc.)
//  stay live regardless of which sub-NSHostingController holds focus.
//

import Foundation
import Observation

@MainActor
@Observable
final class CommandActionsRegistry {
    static let shared = CommandActionsRegistry()

    /// The actions belonging to the currently key main window. `nil` when the
    /// key window is not a main window (welcome / connection-form / settings).
    var current: MainContentCommandActions?

    private init() {}
}
