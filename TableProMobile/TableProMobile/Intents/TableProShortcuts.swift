import AppIntents

struct TableProShortcuts: AppShortcutsProvider {
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
