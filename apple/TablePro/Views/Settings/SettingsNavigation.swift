import Foundation

enum SettingsSectionID: String, CaseIterable, Sendable {
    case app
    case workspace
    case integrations
    case account
}

struct SettingsSection: Equatable, Sendable {
    let id: SettingsSectionID
    let panes: [SettingsPane]
}

enum SettingsSidebarRow: Hashable, Sendable {
    case pane(SettingsPane)
    case page(title: String, location: SettingsLocation)
    case spacer(before: SettingsSectionID)
}

struct SettingsSearchResult: Hashable, Sendable {
    struct Page: Hashable, Sendable {
        let title: String
        let location: SettingsLocation
    }

    let pane: SettingsPane
    let pages: [Page]
}

// A root location matches its pane; any other location lists as a page row under it.
struct SettingsSearchEntry: Hashable, Sendable {
    let title: String
    let keywords: [String]
    let location: SettingsLocation

    init(title: String, keywords: [String] = [], location: SettingsLocation) {
        self.title = title
        self.keywords = keywords
        self.location = location
    }
}

enum SettingsNavigation {
    static let sections: [SettingsSection] = [
        SettingsSection(id: .app, panes: [.general, .appearance, .notifications, .keyboard]),
        SettingsSection(id: .workspace, panes: [.connections, .profiles, .sidebar, .editor, .data]),
        SettingsSection(id: .integrations, panes: [.ai, .mcp, .plugins]),
        SettingsSection(id: .account, panes: [.sync, .account]),
    ]

    static let orderedPanes: [SettingsPane] = sections.flatMap(\.panes)

    static let defaultPane: SettingsPane = .general

    static func pane(forURLIdentifier identifier: String) -> SettingsPane? {
        SettingsPane(urlIdentifier: identifier)
    }

    // Dynamic entries are names only the running app knows: plugin names, AI provider names.
    static func results(matching query: String, adding dynamicEntries: [SettingsSearchEntry] = []) -> [SettingsSearchResult] {
        index(adding: dynamicEntries).results(matching: query)
    }

    static func panes(matching query: String, adding dynamicEntries: [SettingsSearchEntry] = []) -> [SettingsPane] {
        results(matching: query, adding: dynamicEntries).map(\.pane)
    }

    static func rows(matching query: String, adding dynamicEntries: [SettingsSearchEntry] = []) -> [SettingsSidebarRow] {
        guard SettingsSearchIndex.isFiltering(query) else {
            return sections.enumerated().flatMap { offset, section -> [SettingsSidebarRow] in
                let spacer: [SettingsSidebarRow] = offset == 0 ? [] : [.spacer(before: section.id)]
                return spacer + section.panes.map { .pane($0) }
            }
        }
        return results(matching: query, adding: dynamicEntries).flatMap { result -> [SettingsSidebarRow] in
            [.pane(result.pane)] + result.pages.map { .page(title: $0.title, location: $0.location) }
        }
    }

    static var standardEntries: [SettingsSearchEntry] {
        let panes = SettingsPane.allCases.map {
            SettingsSearchEntry(title: $0.title, keywords: $0.searchKeywords, location: .root($0))
        }
        let pages = SettingsPage.allCases.map {
            SettingsSearchEntry(title: $0.title, keywords: $0.searchKeywords, location: SettingsLocation(page: $0))
        }
        return panes + pages
    }

    private static let standardIndex = SettingsSearchIndex(entries: standardEntries)

    private static func index(adding dynamicEntries: [SettingsSearchEntry]) -> SettingsSearchIndex {
        dynamicEntries.isEmpty ? standardIndex : standardIndex.adding(dynamicEntries)
    }
}

// Each term must start a word of one entry, so "date" never finds "Update".
struct SettingsSearchIndex: Sendable {
    private struct Prepared: Sendable {
        let entry: SettingsSearchEntry
        let wordStarts: [String]

        func matches(_ terms: [String]) -> Bool {
            terms.allSatisfy { term in wordStarts.contains { $0.hasPrefix(term) } }
        }
    }

    private let locale: Locale
    private let prepared: [Prepared]

    init(entries: [SettingsSearchEntry], locale: Locale = .current) {
        self.locale = locale
        self.prepared = entries.map { Self.prepare($0, locale: locale) }
    }

    private init(locale: Locale, prepared: [Prepared]) {
        self.locale = locale
        self.prepared = prepared
    }

    func adding(_ entries: [SettingsSearchEntry]) -> SettingsSearchIndex {
        SettingsSearchIndex(locale: locale, prepared: prepared + entries.map { Self.prepare($0, locale: locale) })
    }

    func results(matching query: String) -> [SettingsSearchResult] {
        let terms = Self.terms(in: query, locale: locale)
        guard !terms.isEmpty else {
            return SettingsNavigation.orderedPanes.map { SettingsSearchResult(pane: $0, pages: []) }
        }
        var matchedPanes: Set<SettingsPane> = []
        var pages: [SettingsPane: [SettingsSearchResult.Page]] = [:]
        for item in prepared where item.matches(terms) {
            let location = item.entry.location
            if location.isRoot {
                matchedPanes.insert(location.pane)
            } else if pages[location.pane]?.contains(where: { $0.location == location }) != true {
                pages[location.pane, default: []].append(.init(title: item.entry.title, location: location))
            }
        }
        return SettingsNavigation.orderedPanes.compactMap { pane in
            let panePages = pages[pane] ?? []
            guard matchedPanes.contains(pane) || !panePages.isEmpty else { return nil }
            return SettingsSearchResult(pane: pane, pages: panePages)
        }
    }

    static func isFiltering(_ query: String, locale: Locale = .current) -> Bool {
        !terms(in: query, locale: locale).isEmpty
    }

    static func terms(in query: String, locale: Locale) -> [String] {
        query.split(whereSeparator: \.isWhitespace)
            .map { fold(String($0).trimmingCharacters(in: .punctuationCharacters), locale: locale) }
            .filter { term in term.contains { $0.isLetter || $0.isNumber } }
    }

    static func fold(_ text: String, locale: Locale) -> String {
        // Vietnamese đ is a letter of its own, not d with a diacritic, so folding keeps it.
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
            .replacingOccurrences(of: "đ", with: "d")
    }

    private static func prepare(_ entry: SettingsSearchEntry, locale: Locale) -> Prepared {
        let texts = [entry.title] + entry.keywords
        return Prepared(entry: entry, wordStarts: texts.flatMap { wordStarts(in: fold($0, locale: locale)) })
    }

    // Han text has no spaces, so each ideograph also starts a word.
    private static func wordStarts(in text: String) -> [String] {
        var starts: Set<String.Index> = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            starts.insert(range.lowerBound)
        }
        for index in text.indices where text[index].unicodeScalars.first?.properties.isIdeographic == true {
            starts.insert(index)
        }
        return starts.map { String(text[$0...]) }
    }
}

extension SettingsPane {
    // Visible labels in the user's language, then English terms that stay searchable in every language.
    var searchKeywords: [String] {
        localizedSearchKeywords + searchAliases
    }

    private var localizedSearchKeywords: [String] {
        switch self {
        case .general:
            [
                String(localized: "Language"),
                String(localized: "When TablePro starts"),
                String(localized: "Privacy"),
                String(localized: "Share usage data"),
                String(localized: "Reset all settings"),
            ]
        case .appearance:
            [
                String(localized: "Themes"),
                String(localized: "Light theme"),
                String(localized: "Dark theme"),
            ]
        case .notifications:
            [
                String(localized: "Show notifications"),
                String(localized: "Treat work as long-running after"),
            ]
        case .keyboard:
            [
                String(localized: "Restore Defaults…"),
            ]
        case .connections:
            [
                String(localized: "Check open connections"),
                String(localized: "Query timeout"),
                String(localized: "Recent Connections"),
                String(localized: "Show recent connections"),
                String(localized: "Connection history"),
                String(localized: "Clear Recent"),
            ]
        case .profiles:
            [
                String(localized: "Credential Profiles"),
                String(localized: "SSH Profiles"),
            ]
        case .sidebar:
            [
                String(localized: "Sidebar"),
                String(localized: "Objects"),
                String(localized: "Tabs"),
                String(localized: "Show connections"),
                String(localized: "Show recent tables"),
                String(localized: "Default layout"),
                String(localized: "Show icons"),
                String(localized: "Show comments"),
                String(localized: "Show system databases and schemas"),
                String(localized: "Show partitions"),
                String(localized: "Row size"),
                String(localized: "Enable preview tabs"),
            ]
        case .editor:
            [
                String(localized: "Font"),
                String(localized: "Size"),
                String(localized: "Display"),
                String(localized: "Gutter"),
                String(localized: "Editing"),
                String(localized: "Highlight current line"),
                String(localized: "Highlight current statement"),
                String(localized: "Show invisible characters"),
                String(localized: "Word wrap"),
                String(localized: "Show line numbers"),
                String(localized: "Code folding"),
                String(localized: "Run button beside each statement"),
                String(localized: "Key bindings"),
                String(localized: "Tab width"),
                String(localized: "Keyword case"),
                String(localized: "Query parameters"),
            ]
        case .data:
            [
                String(localized: "Grid"),
                String(localized: "Font"),
                String(localized: "Font size"),
                String(localized: "Row height"),
                String(localized: "Show alternate row backgrounds"),
                String(localized: "Show row numbers"),
                String(localized: "Wrap text in cells"),
                String(localized: "Show invisible characters"),
                String(localized: "Show inspector when a row is selected"),
                String(localized: "Values"),
                String(localized: "Date format"),
                String(localized: "NULL display"),
                String(localized: "Color values by type"),
                String(localized: "Smart value detection"),
                String(localized: "Default JSON view"),
                String(localized: "Sorting"),
                String(localized: "Default sort"),
                String(localized: "Sort direction"),
                String(localized: "Copying"),
                String(localized: "Copy rows as"),
                String(localized: "Pages and Limits"),
                String(localized: "Page size"),
                String(localized: "Exact row count"),
                String(localized: "Query result limit"),
                String(localized: "Results kept per run"),
            ]
        case .ai:
            [
                String(localized: "Enable AI features"),
                String(localized: "Active provider"),
                String(localized: "Providers"),
                String(localized: "Add Provider"),
                AppleIntelligenceAvailability.displayName,
                String(localized: "Inline Suggestions"),
                String(localized: "Suggest SQL while typing"),
                String(localized: "Agent"),
                String(localized: "Tool call limit"),
                String(localized: "Context"),
                String(localized: "Maximum tables"),
                String(localized: "Default AI policy"),
                String(localized: "Privacy"),
            ]
        case .mcp:
            [
                String(localized: "MCP server"),
                String(localized: "Status"),
                String(localized: "Clients"),
                String(localized: "Connect a Client…"),
                String(localized: "Activity"),
                String(localized: "Access"),
                String(localized: "Approval"),
                String(localized: "Approved connections"),
                String(localized: "Allow apps to list connections hidden from AI"),
                String(localized: "Server"),
                String(localized: "Port"),
                String(localized: "Default row limit"),
                String(localized: "Maximum row limit"),
                String(localized: "Query timeout"),
                String(localized: "Log MCP queries in history"),
                String(localized: "Outside MCP Servers"),
                String(localized: "Add Server…"),
            ]
        case .plugins:
            [
                String(localized: "Modules"),
                String(localized: "Database Drivers"),
                String(localized: "Export Formats"),
                String(localized: "Import Formats"),
                String(localized: "Install from File…"),
                String(localized: "Couldn't Load"),
            ] + AppModule.allCases.map(\.title)
        case .sync:
            [
                String(localized: "Sync this Mac with"),
                "TablePro Sync",
                String(localized: "Delete iCloud Data…"),
                String(localized: "Last synced"),
                String(localized: "Sync Now"),
                String(localized: "What Syncs"),
                String(localized: "Connections"),
                String(localized: "Passwords"),
                String(localized: "Groups & Tags"),
                String(localized: "SSH Profiles"),
                String(localized: "Credential Profiles"),
                String(localized: "Table Favorites"),
                String(localized: "Table Folders"),
                String(localized: "Database Favorites"),
                String(localized: "Saved Queries"),
            ]
        case .account:
            [
                String(localized: "Plan"),
                String(localized: "Sign In"),
                String(localized: "Sign Out…"),
                String(localized: "Upgrade…"),
            ]
        }
    }

    // A term listed on one pane only (theme, license, shortcut, MCP, SQL) stays off every other pane.
    private var searchAliases: [String] {
        switch self {
        case .general:
            ["language", "startup", "launch", "privacy", "analytics", "telemetry", "reset", "relaunch"]
        case .appearance:
            [
                "theme", "themes", "dark", "light", "dark mode", "light mode", "appearance mode", "system", "color",
                "colour", "import theme", "export theme", "custom theme", "vs code",
            ]
        case .notifications:
            ["alert", "notify", "notification", "banner", "long-running", "threshold", "duration", "permission", "agent"]
        case .keyboard:
            ["shortcut", "shortcuts", "key", "keys", "binding", "bindings", "hotkey", "key equivalent", "chord", "menu"]
        case .connections:
            [
                "connection", "recent", "recent connections", "clear recent", "welcome", "switcher", "last connected",
                "history", "health check", "keep alive", "heartbeat", "ping", "serverless", "idle", "query timeout", "timeout",
            ]
        case .profiles:
            [
                "credential", "credentials", "ssh", "ssh servers", "password", "profile", "bastion", "vault", "keychain",
                "tunnel", "jump host", "totp", "pgpass", "private key",
            ]
        case .sidebar:
            [
                "sidebar", "tabs", "preview tabs", "show connections", "strip", "recent tables", "default layout", "tree",
                "list", "object icons", "object comments", "system databases", "schemas", "partitions", "row size",
                "density", "view options",
            ]
        case .editor:
            [
                "font", "sql", "format", "formatter", "formatting", "indent", "gutter", "code", "vim", "emacs",
                "key bindings", "line numbers", "word wrap", "wrap", "invisible", "folding", "run button", "tab width",
                "keyword case", "uppercase", "lowercase", "parameters", "family", "size", "preview",
            ]
        case .data:
            [
                "grid", "results", "rows", "pagination", "null", "page size", "font", "date", "json", "sort", "copy",
                "csv", "tsv", "markdown", "wrap", "invisible", "inspector", "limit", "cap", "count", "row height",
                "timestamp", "uuid",
            ]
        case .ai:
            [
                "assistant", "model", "provider", "chat", "copilot", "claude", "codex", "openai", "anthropic", "ollama",
                "gemini", "api key", "slash command", "agent", "completion", "suggestion", "ai policy", "llm",
            ]
        case .mcp:
            [
                "mcp", "server", "token", "client", "integration", "port", "claude desktop", "cursor", "pairing",
                "approval", "outside servers", "remote server", "row limit", "model context protocol",
            ]
        case .plugins:
            [
                "extension", "extensions", "plugin", "plugins", "driver", "drivers", "module", "install", "uninstall",
                "registry", "tableplugin",
            ]
        case .sync:
            [
                "icloud", "apple account", "keychain", "password", "connections", "saved queries", "favorites", "folders",
                "credential", "device", "last synced", "sync now", "cloudkit", "tablepro sync", "provider", "move",
                "end-to-end",
            ]
        case .account:
            [
                "license", "license key", "plan", "subscription", "team", "teams", "pro", "sign in", "sign out",
                "devices", "device", "billing", "payment", "offline", "machine id", "verify", "refresh", "features",
                "upgrade", "account",
            ]
        }
    }
}

extension SettingsPage {
    var searchKeywords: [String] {
        localizedSearchKeywords + searchAliases
    }

    private var localizedSearchKeywords: [String] {
        switch self {
        case .softwareUpdate: [String(localized: "Update channel"), String(localized: "What's New")]
        case .commandLineTool: []
        case .manageThemes: []
        case .linkedFolders: [String(localized: "Add Folder…"), String(localized: "Show in Finder")]
        case .trustedLinks: [String(localized: "Forget All…")]
        case .sqlFormatting:
            [
                String(localized: "Indentation"),
                String(localized: "Line Breaks"),
                String(localized: "Rules file"),
                String(localized: "Commas"),
                String(localized: "Line width"),
                String(localized: "Join condition"),
                String(localized: "Align column aliases"),
            ]
        case .filters:
            [
                String(localized: "Default column"),
                String(localized: "Default operator"),
                String(localized: "Column order"),
                String(localized: "Saved filters"),
                String(localized: "Always show the filter bar"),
            ]
        case .queryHistory: [String(localized: "Clear query history")]
        case .dataRewind: [String(localized: "Clear saved changes")]
        case .slashCommands: [String(localized: "Add Command…")]
        case .mcpApprovals: []
        case .mcpTokens: [String(localized: "Generate Token")]
        case .accountFeatures, .accountDevices, .accountTeams, .accountOffline: []
        case .accountEncryption:
            [String(localized: "Recovery key"), String(localized: "Replace…"), String(localized: "Devices With Your Keys")]
        }
    }

    private var searchAliases: [String] {
        switch self {
        case .softwareUpdate: ["update", "updates", "beta", "channel", "sparkle", "version", "automatic updates"]
        case .commandLineTool: ["cli", "command line", "terminal", "tablepro command", "shell"]
        case .manageThemes: ["theme library", "import theme", "export theme", "custom theme", "theme editor", "vs code"]
        case .linkedFolders: ["linked folders", "watched folder", "shared connections", "shared folder", "team folder"]
        case .trustedLinks: ["trusted", "links", "url", "deep link", "forget"]
        case .sqlFormatting: ["formatter", "format", "beautify", "pretty print", "indent", "uppercase", "lowercase"]
        case .filters: ["filter", "filter bar", "where", "restore filters", "default column", "default operator"]
        case .queryHistory: ["history", "cleanup", "retention", "clear history", "max entries"]
        case .dataRewind: ["rewind", "undo", "saved changes", "restore"]
        case .slashCommands: ["slash command", "command", "prompt", "template"]
        case .mcpApprovals: ["approved", "approval", "grants", "forget"]
        case .mcpTokens: ["token", "tokens", "access token", "revoke", "bearer"]
        case .accountFeatures: ["pro features", "plan features"]
        case .accountDevices: ["device", "this mac", "machine", "activation"]
        case .accountTeams: ["team", "organization", "members"]
        case .accountEncryption: ["e2e", "encryption", "recovery key", "approve device", "keys", "sign out"]
        case .accountOffline: ["license key", "offline", "machine id", "activation file"]
        }
    }
}
