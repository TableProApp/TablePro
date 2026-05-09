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
    }
}
