//
//  ToolbarSubject.swift
//  TablePro
//

import Foundation
import Observation

/// Which connection the window's toolbar is about. The toolbar belongs to the window; its subject
/// is whichever connection the window is showing, and that changes.
///
/// Items used to capture the coordinator they were built with, so a switch could only be expressed
/// by throwing the whole toolbar away and building another. Reading the subject inside a SwiftUI
/// body is what registers observation, so pointing it somewhere else invalidates the two hosted
/// item trees and nothing else. `NSWindow.toolbar` is never reassigned, which is worth as much as
/// the rebuild itself: assigning an already-built toolbar still costs several milliseconds because
/// AppKit rebuilds the titlebar hierarchy for it.
///
/// The reference is weak on purpose. The coordinator is owned by `ConnectionWorkspace.sessionState`
/// and leaves `MainContentCoordinator.activeCoordinators` only on deinit, so a toolbar that held it
/// strongly would keep a torn-down connection alive and voting in every aggregate that walks that
/// registry.
@MainActor
@Observable
internal final class ToolbarSubject {
    internal weak var coordinator: MainContentCoordinator?

    internal init(coordinator: MainContentCoordinator? = nil) {
        self.coordinator = coordinator
    }
}
