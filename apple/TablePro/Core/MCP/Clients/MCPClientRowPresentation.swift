import Foundation

enum MCPClientActionKind: Equatable, Sendable {
    case install
    case update
    case remove
}

enum MCPClientActivity: Equatable, Sendable {
    case running(MCPClientActionKind)
    case handedOff
    case failed(MCPClientActionKind, message: String, output: String?)
}

enum MCPClientConnection: Equatable, Sendable {
    case notConnected
    case connected
    case justConnected
}

enum MCPClientRowAction: Equatable, Sendable {
    case install(handsOff: Bool)
    case update(handsOff: Bool)
    case copy

    var title: String {
        switch self {
        case .install(let handsOff):
            if handsOff { String(localized: "Install…") } else { String(localized: "Install") }
        case .update(let handsOff):
            if handsOff { String(localized: "Update…") } else { String(localized: "Update") }
        case .copy:
            String(localized: "Copy")
        }
    }

    // Every row's button reads the same verb, so VoiceOver needs the client's name to tell them apart.
    func accessibilityLabel(clientName: String) -> String {
        switch self {
        case .install:
            String(format: String(localized: "Install in %@"), clientName)
        case .update:
            String(format: String(localized: "Update in %@"), clientName)
        case .copy:
            String(format: String(localized: "Copy Setup for %@"), clientName)
        }
    }
}

struct MCPClientRowPresentation: Equatable, Sendable {
    let title: String
    let subtitle: String
    let status: String?
    let action: MCPClientRowAction?
    let isBusy: Bool

    init(row: MCPClientRow, activity: MCPClientActivity?, connection: MCPClientConnection) {
        title = row.name
        if case .running = activity {
            isBusy = true
        } else {
            isBusy = false
        }
        if let unsupported = row.unsupported {
            subtitle = Self.unsupportedSubtitle(unsupported)
            status = nil
            action = nil
            return
        }
        var route = row.config.needsUpdate ? row.updateRoute : row.installRoute
        if row.config == .unreadable, route == .file {
            route = .copy
        }
        subtitle = Self.subtitle(route: route, row: row)
        status = Self.status(row: row, activity: activity, connection: connection)
        action = isBusy ? nil : Self.action(row: row)
    }

    static func action(row: MCPClientRow) -> MCPClientRowAction? {
        guard row.unsupported == nil else { return nil }
        switch row.config {
        case .current, .shadowed, .disabled, .usesToken:
            return nil
        case .moved, .otherCopy, .outdated:
            return row.updateRoute == .copy ? .copy : .update(handsOff: row.updateRoute.handsOff)
        case .notConfigured, .otherScope, .unreadable, .unknown:
            if row.installRoute == .copy || (row.config == .unreadable && row.installRoute == .file) {
                return row.copyText == nil ? nil : .copy
            }
            return .install(handsOff: row.installRoute.handsOff)
        }
    }

    private static func status(
        row: MCPClientRow,
        activity: MCPClientActivity?,
        connection: MCPClientConnection
    ) -> String? {
        switch activity {
        case .running(let kind):
            return runningStatus(kind)
        case .failed(let kind, _, _):
            return failedStatus(kind)
        case .handedOff where !row.config.hasEntry && connection == .notConnected:
            return String(format: String(localized: "Finish in %@"), row.name)
        case .handedOff, .none:
            break
        }
        switch connection {
        case .justConnected:
            return String(localized: "Connected just now")
        case .connected:
            return String(localized: "Connected")
        case .notConnected:
            break
        }
        switch row.config {
        case .current:
            return String(localized: "Set up")
        case .moved:
            return String(localized: "TablePro moved")
        case .otherCopy:
            return String(localized: "Uses another copy")
        case .outdated:
            return String(localized: "Out of date")
        case .shadowed:
            return String(localized: "Old setup in a project")
        case .otherScope:
            return String(localized: "One project only")
        case .disabled:
            return String(localized: "Turned off")
        case .usesToken:
            return String(localized: "Set up with a token")
        case .unreadable:
            return String(localized: "Can't read settings")
        case .notConfigured, .unknown:
            return row.isInstalled ? nil : String(localized: "Not found")
        }
    }

    private static func runningStatus(_ kind: MCPClientActionKind) -> String {
        switch kind {
        case .install: String(localized: "Installing…")
        case .update: String(localized: "Updating…")
        case .remove: String(localized: "Removing…")
        }
    }

    private static func failedStatus(_ kind: MCPClientActionKind) -> String {
        switch kind {
        case .install: String(localized: "Couldn't install")
        case .update: String(localized: "Couldn't update")
        case .remove: String(localized: "Couldn't remove")
        }
    }

    private static func subtitle(route: MCPClientRoute, row: MCPClientRow) -> String {
        switch route {
        case .deeplink:
            return String(format: String(localized: "Opens %@ to confirm"), row.name)
        case .cli(let binary):
            return String(format: String(localized: "Adds through the %@ command"), binary)
        case .file:
            return String(format: String(localized: "Edits %@"), row.displayConfigPath ?? row.name)
        case .copy:
            if let path = row.displayConfigPath, row.isConfigWritable {
                return String(format: String(localized: "Copy the setup into %@"), path)
            }
            if row.commandLine != nil {
                return String(localized: "Copy the command and run it in Terminal")
            }
            return String(format: String(localized: "Add it in %@'s settings"), row.name)
        }
    }

    private static func unsupportedSubtitle(_ reason: MCPClientUnsupported) -> String {
        switch reason {
        case .remoteOnly:
            String(localized: "Reaches only servers on the internet")
        case .stdioOnly:
            String(localized: "Starts only local command servers")
        }
    }
}

enum MCPClientDetailText {
    static func applies(_ moment: MCPClientApplyMoment, name: String) -> String {
        switch moment {
        case .live:
            String(format: String(localized: "%@ picks up the change right away."), name)
        case .newSession:
            String(format: String(localized: "Start a new %@ session to load it."), name)
        case .restartApp:
            String(format: String(localized: "Quit and reopen %@ to load it."), name)
        case .reload:
            String(format: String(localized: "Reload %@ to load it."), name)
        }
    }

    static func unsupported(_ reason: MCPClientUnsupported, name: String) -> String {
        switch reason {
        case .remoteOnly:
            String(
                format: String(localized: "%@ reaches MCP servers only from its maker's cloud, so it cannot reach TablePro on this Mac."),
                name
            )
        case .stdioOnly:
            String(
                format: String(localized: "%@ starts MCP servers only as local commands, so it cannot reach TablePro's HTTP server."),
                name
            )
        }
    }

    static func configState(_ state: MCPClientConfigState, name: String) -> String? {
        switch state {
        case .moved:
            String(format: String(localized: "%@ is set up for a copy of TablePro that is no longer there."), name)
        case .otherCopy:
            String(format: String(localized: "%@ is set up for a different copy of TablePro. Update points it to this one."), name)
        case .outdated:
            String(format: String(localized: "%@ is set up with an address or token that no longer works."), name)
        case .shadowed(let project):
            String(
                format: String(localized: "%1$@ is set up, but the project %2$@ has its own older TablePro setup that wins there. Remove TablePro from that project's settings."),
                name,
                project
            )
        case .otherScope:
            String(format: String(localized: "%@ has TablePro in one project only. Install adds it for every project."), name)
        case .disabled:
            String(format: String(localized: "TablePro is turned off in %1$@. Turn it on in %1$@'s MCP settings to use it."), name)
        case .usesToken:
            String(
                format: String(localized: "%@ connects with a token from Settings > MCP > Authentication, which can limit what it reaches. TablePro leaves it as is."),
                name
            )
        case .unreadable:
            String(format: String(localized: "TablePro could not read %@'s settings file, so it leaves the file alone. Copy the setup and add it by hand."), name)
        case .current, .notConfigured, .unknown:
            nil
        }
    }
}
