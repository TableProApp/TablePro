//
//  TableProShortcuts.swift
//  TablePro
//

import AppIntents
import Combine
import Foundation

@available(macOS 14.0, *)
internal struct TableProShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenConnectionIntent(),
            phrases: [
                "Open \(\.$connection) in \(.applicationName)",
                "Connect to \(\.$connection) in \(.applicationName)"
            ],
            shortTitle: "Open Connection",
            systemImageName: "server.rack"
        )
        AppShortcut(
            intent: RunQueryIntent(),
            phrases: [
                "Run a query in \(.applicationName)"
            ],
            shortTitle: "Run Query",
            systemImageName: "play.rectangle"
        )
        AppShortcut(
            intent: AddRowToTableIntent(),
            phrases: [
                "Add a row in \(.applicationName)"
            ],
            shortTitle: "Add Row to Table",
            systemImageName: "plus.rectangle.on.folder"
        )
        AppShortcut(
            intent: AddRowsToTableIntent(),
            phrases: [
                "Add rows in \(.applicationName)"
            ],
            shortTitle: "Add Rows to Table",
            systemImageName: "rectangle.stack.badge.plus"
        )
    }
}

// Siri's "Open <connection>" phrases read the connection names, so they follow every change to the list.
@available(macOS 14.0, *)
@MainActor
internal final class ShortcutsParameterRefresher {
    internal static let shared = ShortcutsParameterRefresher()

    private var cancellable: AnyCancellable?

    internal func start(appEvents: AppEvents = .shared) {
        guard cancellable == nil else { return }
        TableProShortcuts.updateAppShortcutParameters()
        cancellable = appEvents.connectionUpdated
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { _ in TableProShortcuts.updateAppShortcutParameters() }
    }
}
