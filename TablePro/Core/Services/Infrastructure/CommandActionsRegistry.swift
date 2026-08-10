//
//  CommandActionsRegistry.swift
//  TablePro
//
//  Tracks the `MainContentCommandActions` of the currently key main window for
//  SwiftUI views that need it while they do not hold focus. `@FocusedValue` only
//  resolves for the focused view hierarchy, and each `NSHostingController` in a
//  main window is its own scene context, so an unfocused panel reads nil.
//
//  The menu bar does not use this. Menu items dispatch through the responder
//  chain, which resolves the key window's own controller every time.
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
