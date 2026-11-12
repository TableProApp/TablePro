import Foundation
import TableProMCPClients

enum MCPClientConfigState: Equatable, Sendable {
    case notConfigured
    case current
    case moved
    case otherCopy
    case outdated
    // `project` is the folder whose own setup wins there, as the detail text shows it.
    case shadowed(project: String)
    case otherScope
    case disabled
    case usesToken
    case unreadable
    case unknown

    init(_ status: MCPClientConfigStatus, displayPath: (String) -> String = { $0 }) {
        switch status {
        case .notConfigured:
            self = .notConfigured
        case .current:
            self = .current
        case .stale(let reason):
            switch reason {
            case .commandMissing:
                self = .moved
            case .otherCommand:
                self = .otherCopy
            case .otherURL, .otherToken:
                self = .outdated
            case .shadowed(let scope):
                self = .shadowed(project: displayPath(scope))
            }
        case .otherScope:
            self = .otherScope
        case .disabled:
            self = .disabled
        case .usesToken:
            self = .usesToken
        case .unreadable:
            self = .unreadable
        case .unknown:
            self = .unknown
        }
    }

    var hasEntry: Bool {
        switch self {
        case .current, .moved, .otherCopy, .outdated, .shadowed, .disabled, .usesToken: true
        case .notConfigured, .otherScope, .unreadable, .unknown: false
        }
    }

    var needsUpdate: Bool {
        switch self {
        case .moved, .otherCopy, .outdated: true
        case .current, .shadowed, .notConfigured, .otherScope, .disabled, .usesToken, .unreadable, .unknown: false
        }
    }

    // The user's own choice: a token they scoped, or TablePro turned off in the client. Install or Update would undo it.
    var isUserChoice: Bool {
        self == .usesToken || self == .disabled
    }

    var isShadowed: Bool {
        if case .shadowed = self { return true }
        return false
    }
}

enum MCPClientRoute: Equatable, Sendable {
    case deeplink(scheme: String)
    case cli(binary: String)
    case file
    case copy

    var handsOff: Bool {
        if case .deeplink = self { return true }
        return false
    }
}

enum MCPClientUnsupported: Equatable, Sendable {
    case remoteOnly
    case stdioOnly
}

enum MCPClientApplyMoment: Equatable, Sendable {
    case live
    case newSession
    case restartApp
    case reload
}

struct MCPClientRow: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let iconSlug: String
    let isDetected: Bool
    let isInstalled: Bool
    let config: MCPClientConfigState
    let installRoute: MCPClientRoute
    let updateRoute: MCPClientRoute
    let removeRoute: MCPClientRoute?
    let unsupported: MCPClientUnsupported?
    let applies: MCPClientApplyMoment?
    let configPath: String?
    let displayConfigPath: String?
    let configFileExists: Bool
    let isConfigWritable: Bool
    let snippet: String?
    let commandLine: String?

    // A file only the client may write (Claude Code's .claude.json) is set up through its command, not pasted into.
    var copyText: String? {
        if let commandLine, !isConfigWritable { return commandLine }
        return snippet ?? commandLine
    }

    var configFileName: String? {
        configPath.map { ($0 as NSString).lastPathComponent }
    }
}

struct MCPClientScanner: Sendable {
    let catalog: MCPClientCatalog
    let context: MCPClientSetupContext

    func scan() -> [MCPClientRow] {
        catalog.clients.compactMap(row(for:))
    }

    func row(for client: MCPClientDefinition) -> MCPClientRow? {
        guard let spec = client.spec(for: .macos) else { return nil }
        let location = catalog.location(for: client, platform: .macos)
        let configPath = location.map { context.expand($0.path) }
        let fileExists = configPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        let config = configState(location: location, path: configPath, fileExists: fileExists)
        let detected = spec.detect.contains(where: isDetected)
        let isInstalled = detected || config.hasEntry || config == .otherScope
        let isWritable = location.map { $0.isWritable && $0.format != .yaml } ?? false

        let renderer = MCPTemplateRenderer(serverName: catalog.serverName, target: .stdio(command: context.bridgePath))
        let unsupported = spec.unsupported.map(Self.unsupported)
        let entry = unsupported == nil ? try? renderer.entry(spec) : nil

        let available = unsupported == nil ? availableRoutes(spec, isWritable: isWritable) : []
        let installRoute = isInstalled ? (available.first ?? .copy) : .copy
        // Update merges into the file and keeps the user's own keys; a client's add command replaces the whole entry.
        let updateRoute = isInstalled
            ? (available.first { $0 == .file } ?? available.first { !$0.handsOff } ?? available.first ?? .copy)
            : .copy
        // A shadowed row's user entry works; Remove would take it out and leave the project's old one in charge.
        let removeRoute = config.hasEntry && !config.isShadowed && unsupported == nil
            ? removalRoute(spec, isWritable: isWritable, fileExists: fileExists)
            : nil

        return MCPClientRow(
            id: client.id,
            name: client.name,
            iconSlug: client.icon,
            isDetected: detected,
            isInstalled: isInstalled,
            config: config,
            installRoute: installRoute,
            updateRoute: updateRoute,
            removeRoute: removeRoute,
            unsupported: unsupported,
            applies: spec.applies.map(Self.applyMoment),
            configPath: configPath,
            displayConfigPath: configPath.map(context.displayPath),
            configFileExists: fileExists,
            isConfigWritable: isWritable,
            snippet: entry.map { renderer.snippet(for: location, entry: $0) },
            commandLine: entry.flatMap { commandLine(spec, renderer: renderer, entry: $0) }
        )
    }

    func executable(named binary: String) -> URL? {
        context.executable(named: binary, catalogPaths: catalogPaths(forBinary: binary))
    }

    func detectedIDs(among ids: Set<String>) -> Set<String> {
        let found = catalog.clients.filter { client in
            ids.contains(client.id) && client.spec(for: .macos)?.detect.contains(where: isDetected) == true
        }
        return Set(found.map(\.id))
    }

    private func configState(location: MCPConfigLocation?, path: String?, fileExists: Bool) -> MCPClientConfigState {
        guard let location, let path else { return .unknown }
        var text: String?
        if fileExists {
            guard let read = try? String(contentsOfFile: path, encoding: .utf8) else { return .unreadable }
            text = read
        }
        let status = MCPClientStatusEvaluator.status(
            configText: text,
            location: location,
            serverName: catalog.serverName,
            expected: .stdio(command: context.bridgePath),
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
        return MCPClientConfigState(status, displayPath: context.displayPath)
    }

    private func isDetected(_ rule: MCPClientDetectRule) -> Bool {
        switch rule {
        case .bundleID(let identifier):
            context.workspace.applicationURL(forBundleIdentifier: identifier) != nil
        case .binary(let name, _):
            executable(named: name) != nil
        case .path(let path):
            FileManager.default.fileExists(atPath: context.expand(path))
        }
    }

    private func availableRoutes(_ spec: MCPClientPlatformSpec, isWritable: Bool) -> [MCPClientRoute] {
        spec.install.compactMap { method -> MCPClientRoute? in
            switch method {
            case .deeplink(let scheme, _):
                hasHandler(forScheme: scheme) ? .deeplink(scheme: scheme) : nil
            case .cli(let cli):
                executable(named: cli.binary) != nil ? .cli(binary: cli.binary) : nil
            case .file:
                isWritable ? .file : nil
            }
        }
    }

    private func removalRoute(_ spec: MCPClientPlatformSpec, isWritable: Bool, fileExists: Bool) -> MCPClientRoute? {
        for method in spec.install {
            switch method {
            case .cli(let cli) where cli.remove != nil && executable(named: cli.binary) != nil:
                return .cli(binary: cli.binary)
            case .file where isWritable && fileExists:
                return .file
            default:
                continue
            }
        }
        return nil
    }

    private func hasHandler(forScheme scheme: String) -> Bool {
        guard let probe = URL(string: "\(scheme)://") else { return false }
        return context.workspace.applicationURL(toOpen: probe) != nil
    }

    private func commandLine(_ spec: MCPClientPlatformSpec, renderer: MCPTemplateRenderer, entry: JSONValue) -> String? {
        guard let cli = spec.cliInstall, let arguments = try? renderer.arguments(cli.add, entry: entry) else { return nil }
        return renderer.commandLine(binary: cli.binary, arguments: arguments)
    }

    private func catalogPaths(forBinary binary: String) -> [String] {
        catalog.clients
            .flatMap { $0.spec(for: .macos)?.detect ?? [] }
            .flatMap { rule -> [String] in
                if case let .binary(name, paths) = rule, name == binary { return paths }
                return []
            }
    }

    private static func unsupported(_ reason: MCPClientUnsupportedReason) -> MCPClientUnsupported {
        switch reason {
        case .remoteOnly: .remoteOnly
        case .stdioOnly: .stdioOnly
        }
    }

    private static func applyMoment(_ applies: MCPClientApplies) -> MCPClientApplyMoment {
        switch applies {
        case .live: .live
        case .newSession: .newSession
        case .restartApp: .restartApp
        case .reload: .reload
        }
    }
}

extension MCPClientPlatformSpec {
    var cliInstall: MCPCLIInstall? {
        for method in install {
            if case .cli(let cli) = method { return cli }
        }
        return nil
    }

    func cliInstall(binary: String) -> MCPCLIInstall? {
        for method in install {
            if case .cli(let cli) = method, cli.binary == binary { return cli }
        }
        return nil
    }

    func deeplinkTemplate(scheme: String) -> String? {
        for method in install {
            if case let .deeplink(candidate, template) = method, candidate == scheme { return template }
        }
        return nil
    }
}
