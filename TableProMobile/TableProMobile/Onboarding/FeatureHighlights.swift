import Foundation

nonisolated struct FeatureHighlight: Identifiable, Sendable {
    let id: String
    let systemImage: String
    let title: LocalizedStringResource
    let message: LocalizedStringResource
}

nonisolated enum FeatureHighlights {
    static let welcome: [FeatureHighlight] = [
        FeatureHighlight(
            id: "databases",
            systemImage: "cylinder.split.1x2",
            title: "Many Databases, One App",
            message: "MySQL, PostgreSQL, SQL Server, Oracle, Redis, SQLite, DuckDB, and more."
        ),
        FeatureHighlight(
            id: "browse",
            systemImage: "tablecells",
            title: "Browse and Edit Data",
            message: "Open a table, filter its rows, and change values in place."
        ),
        FeatureHighlight(
            id: "query",
            systemImage: "chevron.left.forwardslash.chevron.right",
            title: "Write and Run SQL",
            message: "Run queries and find the ones you ran before in History."
        ),
        FeatureHighlight(
            id: "secure",
            systemImage: "lock.shield",
            title: "Connect Securely",
            message: "Passwords stay in your Keychain. Connect through an SSH tunnel or over SSL."
        )
    ]

    static func release(_ version: String) -> [FeatureHighlight]? {
        releases[version]
    }

    private static let releases: [String: [FeatureHighlight]] = [
        "1.0": [
            FeatureHighlight(
                id: "sample",
                systemImage: "music.note.list",
                title: "Sample Database",
                message: "Explore a music store database without connecting to a server."
            ),
            FeatureHighlight(
                id: "sync",
                systemImage: "icloud",
                title: "Syncs with Your Mac",
                message: "Connections, groups, and tags from TablePro on your Mac appear here over iCloud."
            ),
            FeatureHighlight(
                id: "live-activity",
                systemImage: "lock.iphone",
                title: "Queries on the Lock Screen",
                message: "A running query shows its time and row count in a Live Activity."
            ),
            FeatureHighlight(
                id: "shortcuts",
                systemImage: "apps.iphone",
                title: "Shortcuts and Widgets",
                message: "Open a connection or add rows from Shortcuts, Siri, and the Home Screen."
            )
        ]
    ]
}
