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

// A connection opens in a full-screen cover, and a focused value set inside that presentation never reaches the menu
// bar (measured on iPadOS 27: every item stayed disabled), so views inside write here and the scene root publishes it.
@MainActor
@Observable
final class SceneMenuState {
    private(set) var queryEditor: QueryEditorActions?
    private(set) var tabs: ConnectedTabActions?
    @ObservationIgnored private var queryEditorOwner: UUID?
    @ObservationIgnored private var tabsOwner: UUID?

    func publishQueryEditor(_ actions: QueryEditorActions?, from owner: UUID) {
        queryEditorOwner = owner
        queryEditor = actions
    }

    // A view leaving after another took its place leaves the newer value alone.
    func withdrawQueryEditor(_ owner: UUID) {
        guard queryEditorOwner == owner else { return }
        queryEditorOwner = nil
        queryEditor = nil
    }

    func publishTabs(_ actions: ConnectedTabActions, from owner: UUID) {
        tabsOwner = owner
        tabs = actions
    }

    func withdrawTabs(_ owner: UUID) {
        guard tabsOwner == owner else { return }
        tabsOwner = nil
        tabs = nil
    }
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
            // One section: loose items placed before the sidebar group came out in reverse on iPadOS 27.
            Section {
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
            }
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
