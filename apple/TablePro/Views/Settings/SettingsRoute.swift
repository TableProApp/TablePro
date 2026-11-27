import Foundation

enum SettingsPage: CaseIterable, Hashable, Sendable {
    case softwareUpdate
    case commandLineTool
    case manageThemes
    case linkedFolders
    case trustedLinks
    case sqlFormatting
    case filters
    case queryHistory
    case dataRewind
    case slashCommands
    case mcpApprovals
    case mcpTokens
    case accountFeatures
    case accountDevices
    case accountTeams
    case accountEncryption
    case accountOffline

    var parent: SettingsPane {
        switch self {
        case .softwareUpdate, .commandLineTool: .general
        case .manageThemes: .appearance
        case .linkedFolders, .trustedLinks: .connections
        case .sqlFormatting: .editor
        case .filters, .queryHistory, .dataRewind: .data
        case .slashCommands: .ai
        case .mcpApprovals, .mcpTokens: .mcp
        case .accountFeatures, .accountDevices, .accountTeams, .accountEncryption, .accountOffline: .account
        }
    }

    var title: String {
        switch self {
        case .softwareUpdate: String(localized: "Software Update")
        case .commandLineTool: String(localized: "Command Line Tool")
        case .manageThemes: String(localized: "Manage Themes")
        case .linkedFolders: String(localized: "Linked Folders")
        case .trustedLinks: String(localized: "Trusted Links")
        case .sqlFormatting: String(localized: "SQL Formatting")
        case .filters: String(localized: "Filters")
        case .queryHistory: String(localized: "Query History")
        case .dataRewind: String(localized: "Data Rewind")
        case .slashCommands: String(localized: "Slash Commands")
        case .mcpApprovals: String(localized: "Approved Connections")
        case .mcpTokens: String(localized: "Tokens")
        case .accountFeatures: String(localized: "Features")
        case .accountDevices: String(localized: "Devices")
        case .accountTeams: String(localized: "Teams")
        case .accountEncryption: String(localized: "End-to-End Encryption")
        case .accountOffline: String(localized: "Offline File and License Key")
        }
    }

    // Published in tablepro://settings/<pane>/<page> links, so it never follows a title.
    var urlIdentifier: String {
        switch self {
        case .softwareUpdate: "software-update"
        case .commandLineTool: "command-line-tool"
        case .manageThemes: "themes"
        case .linkedFolders: "linked-folders"
        case .trustedLinks: "trusted-links"
        case .sqlFormatting: "sql-formatting"
        case .filters: "filters"
        case .queryHistory: "query-history"
        case .dataRewind: "data-rewind"
        case .slashCommands: "slash-commands"
        case .mcpApprovals: "approvals"
        case .mcpTokens: "tokens"
        case .accountFeatures: "features"
        case .accountDevices: "devices"
        case .accountTeams: "teams"
        case .accountEncryption: "encryption"
        case .accountOffline: "offline"
        }
    }

    var drillIdentifier: String { "settings-drill-\(urlIdentifier)" }
    var pageIdentifier: String { "settings-page-\(urlIdentifier)" }

    init?(urlIdentifier: String, in pane: SettingsPane) {
        guard let page = Self.pages(in: pane).first(where: { $0.urlIdentifier == urlIdentifier }) else { return nil }
        self = page
    }

    static func pages(in pane: SettingsPane) -> [SettingsPage] {
        allCases.filter { $0.parent == pane }
    }
}

enum SettingsRoute: Hashable, Sendable {
    case page(SettingsPage)
    case plugin(id: String)
    // A rejected bundle can carry the id of a loaded plugin, so it is told apart by its URL.
    case rejectedPlugin(URL)
    case aiProvider(UUID)
    // A team's keys, by its scope name, with the name the Teams page listed it under.
    case team(id: String, name: String)

    var pane: SettingsPane {
        switch self {
        case .page(let page): page.parent
        case .plugin, .rejectedPlugin: .plugins
        case .aiProvider: .ai
        case .team: .account
        }
    }

    var page: SettingsPage? {
        if case .page(let page) = self { return page }
        return nil
    }

    var defaultTitle: String {
        switch self {
        case .page(let page): page.title
        case .plugin: String(localized: "Extension")
        case .rejectedPlugin(let url): url.deletingPathExtension().lastPathComponent
        case .aiProvider: String(localized: "AI Provider")
        case .team(_, let name): name
        }
    }
}

extension SettingsRoute: SettingsDrillIdentifying {
    var settingsDrillIdentifier: String? { page?.drillIdentifier }
}

struct SettingsLocation: Hashable, Sendable {
    let pane: SettingsPane
    let routes: [SettingsRoute]

    // A route of another pane could never be shown under this one.
    init(pane: SettingsPane, routes: [SettingsRoute] = []) {
        self.pane = pane
        self.routes = Array(routes.prefix { $0.pane == pane })
    }

    init(page: SettingsPage) {
        self.init(pane: page.parent, routes: [.page(page)])
    }

    init(route: SettingsRoute) {
        self.init(pane: route.pane, routes: [route])
    }

    static func root(_ pane: SettingsPane) -> SettingsLocation {
        SettingsLocation(pane: pane)
    }

    var isRoot: Bool { routes.isEmpty }

    var root: SettingsLocation { .root(pane) }

    // Never fails on a known pane, so a link to a newer page still opens Settings on an older app.
    init?(urlPathSegments segments: [String]) {
        guard let first = segments.first, let pane = SettingsPane(urlIdentifier: first) else { return nil }
        guard segments.count > 1 else {
            self.init(pane: pane)
            return
        }
        let second = segments[1]
        if pane == .plugins {
            self.init(pane: pane, routes: Self.isPluginIdentifier(second) ? [.plugin(id: second)] : [])
        } else if let page = SettingsPage(urlIdentifier: second, in: pane) {
            self.init(page: page)
        } else {
            self.init(pane: pane)
        }
    }

    private static func isPluginIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_")
        }
    }
}
