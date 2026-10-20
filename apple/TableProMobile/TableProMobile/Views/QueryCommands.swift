import SwiftUI

// What the Query menu runs, published by the key window's query editor while its tab shows.
struct QueryEditorActions {
    let runTitle: String
    let canRun: Bool
    let isExecuting: Bool
    let run: () -> Void
    let runAll: () -> Void
    let stop: () -> Void
    let clear: () -> Void

    // A hidden tab and a row pushed over the editor both keep the editor alive, and its text is not what shows.
    static func publishes(isOnScreen: Bool, selectedTab: ConnectedTab) -> Bool {
        isOnScreen && selectedTab == .query
    }
}

struct ConnectedTabActions {
    let select: (ConnectedTab) -> Void
}

extension FocusedValues {
    @Entry var queryEditorActions: QueryEditorActions?
    @Entry var connectedTabActions: ConnectedTabActions?
}

// The iPadOS menu bar lists these with their shortcuts; on iPhone the shortcuts work from a hardware keyboard.
struct QueryCommands: Commands {
    @FocusedValue(\.queryEditorActions) private var actions
    @FocusedValue(\.connectedTabActions) private var tabs

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            Button("Tables") { tabs?.select(.tables) }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(tabs == nil)
            Button("Query") { tabs?.select(.query) }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(tabs == nil)
            Button("History") { tabs?.select(.history) }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(tabs == nil)
            Button("Info") { tabs?.select(.info) }
                .keyboardShortcut("4", modifiers: .command)
                .disabled(tabs == nil)
            Divider()
        }
        CommandMenu("Query") {
            Button(actions?.runTitle ?? String(localized: "Run Statement")) { actions?.run() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!(actions?.canRun ?? false))
            Button("Run All Statements") { actions?.runAll() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(!(actions?.canRun ?? false))
            Button("Stop") { actions?.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!(actions?.isExecuting ?? false))
            Divider()
            Button("Clear Query") { actions?.clear() }
                .disabled(actions == nil)
        }
    }
}
