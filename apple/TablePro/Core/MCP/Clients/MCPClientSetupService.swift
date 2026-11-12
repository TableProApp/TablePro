import AppKit
import Combine
import Foundation
import os
import TableProMCPClients

enum MCPClientActionOutcome: Equatable, Sendable {
    case done(backupPath: String?)
    case handedOff
    case refusedReadOnlyVolume
    case failed(message: String, output: String?)
    case unavailable
}

private struct MCPClientActionFailure: Error {
    let message: String
    let output: String?
}

@MainActor
final class MCPClientSetupService: ObservableObject {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPClientSetup")
    private static let justConnectedDuration: Duration = .seconds(60)

    @Published private(set) var rows: [MCPClientRow] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var activities: [String: MCPClientActivity] = [:]
    @Published private(set) var connectedClientIDs: Set<String> = []
    @Published private(set) var justConnectedClientIDs: Set<String> = []

    let isAppOnReadOnlyVolume: Bool
    var isCatalogAvailable: Bool { catalog != nil }

    private let catalog: MCPClientCatalog?
    private let context: MCPClientSetupContext
    private let runner: any MCPClientCommandRunning
    private let announce: @MainActor (String) -> Void
    private var knownSessionIDs: Set<String>?
    private var sightings: [MCPClientSessionSighting] = []
    private var refreshGeneration = 0
    private var settleTasks: [String: Task<Void, Never>] = [:]
    private var subscriptions: Set<AnyCancellable> = []

    init(
        catalog: MCPClientCatalog? = MCPClientCatalogBundle.shared,
        context: MCPClientSetupContext = .live(),
        runner: any MCPClientCommandRunning = AgentCLICommandRunner(),
        isAppOnReadOnlyVolume: Bool = CommandLineShim.isOnReadOnlyVolume(Bundle.main.bundleURL),
        sessions: AnyPublisher<[MCPClientSessionSighting], Never> = MCPClientSetupService.liveSessions(),
        activations: AnyPublisher<Void, Never> = MCPClientSetupService.liveActivations(),
        announce: @escaping @MainActor (String) -> Void = { AccessibilityAnnouncement.post($0) }
    ) {
        self.catalog = catalog
        self.context = context
        self.runner = runner
        self.isAppOnReadOnlyVolume = isAppOnReadOnlyVolume
        self.announce = announce

        sessions
            .sink { [weak self] sightings in self?.sessionsChanged(sightings) }
            .store(in: &subscriptions)
        activations
            .sink { [weak self] in
                guard let self else { return }
                Task { await self.returnedToTablePro() }
            }
            .store(in: &subscriptions)
    }

    deinit {
        for task in settleTasks.values {
            task.cancel()
        }
    }

    static func liveSessions() -> AnyPublisher<[MCPClientSessionSighting], Never> {
        MCPServerManager.shared.$connectedClients
            .map { snapshots in snapshots.map(MCPClientSessionSighting.init) }
            .eraseToAnyPublisher()
    }

    static func liveActivations() -> AnyPublisher<Void, Never> {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    func row(id: String) -> MCPClientRow? {
        rows.first { $0.id == id }
    }

    func presentation(for row: MCPClientRow) -> MCPClientRowPresentation {
        MCPClientRowPresentation(row: row, activity: activities[row.id], connection: connection(for: row.id))
    }

    func connection(for id: String) -> MCPClientConnection {
        if justConnectedClientIDs.contains(id) { return .justConnected }
        if connectedClientIDs.contains(id) { return .connected }
        return .notConnected
    }

    func refresh() async {
        guard let catalog else {
            hasLoaded = true
            return
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        let scanned = await Self.scan(MCPClientScanner(catalog: catalog, context: context))
        guard generation == refreshGeneration else { return }
        rows = scanned
        hasLoaded = true
        // Which of two rows sharing a session is on this Mac is known only once the rows are scanned.
        connectedClientIDs = connectedIDs(for: sightings, catalog: catalog)
        justConnectedClientIDs.formIntersection(connectedClientIDs)
        for row in scanned where row.config.hasEntry && activities[row.id] == .handedOff {
            activities[row.id] = nil
        }
    }

    // A client with no settings file to read gives no sign the hand-off finished; coming back is the best one.
    func returnedToTablePro() async {
        await refresh()
        for row in rows where row.config == .unknown && activities[row.id] == .handedOff {
            activities[row.id] = nil
        }
    }

    @concurrent
    nonisolated private static func scan(_ scanner: MCPClientScanner) async -> [MCPClientRow] {
        scanner.scan()
    }

    @discardableResult
    func install(_ id: String) async -> MCPClientActionOutcome {
        await perform(.install, on: id)
    }

    @discardableResult
    func update(_ id: String) async -> MCPClientActionOutcome {
        await perform(.update, on: id)
    }

    @discardableResult
    func remove(_ id: String) async -> MCPClientActionOutcome {
        await perform(.remove, on: id)
    }

    func sessionsChanged(_ sightings: [MCPClientSessionSighting]) {
        guard let catalog else { return }
        self.sightings = sightings
        let previouslyConnected = connectedClientIDs
        let connected = connectedIDs(for: sightings, catalog: catalog)
        connectedClientIDs = connected
        justConnectedClientIDs.formIntersection(connected)

        let ids = Set(sightings.map(\.id))
        guard let known = knownSessionIDs else {
            // Sessions already open when the sheet appears read Connected, not just connected.
            knownSessionIDs = ids
            return
        }
        knownSessionIDs = ids
        let arrivals = sightings.filter { !known.contains($0.id) }
        guard !arrivals.isEmpty else { return }

        let detected = detectedClientIDs
        for sighting in arrivals {
            let clientIDs = catalog.clientIDs(forSessionNamed: sighting.clientInfoName, tokenName: sighting.tokenName, detected: detected)
            let fresh = clientIDs.subtracting(previouslyConnected).subtracting(justConnectedClientIDs)
            guard !fresh.isEmpty else { continue }
            for id in fresh {
                markJustConnected(id)
            }
            let client = catalog.client(forSessionNamed: sighting.clientInfoName, tokenName: sighting.tokenName, detected: detected)
            announce(String(format: String(localized: "%@ connected"), client?.name ?? sighting.displayName))
        }
        Task { await self.refresh() }
    }

    private var detectedClientIDs: Set<String> {
        Set(rows.filter { $0.isDetected }.map(\.id))
    }

    private func connectedIDs(for sightings: [MCPClientSessionSighting], catalog: MCPClientCatalog) -> Set<String> {
        let detected = detectedClientIDs
        return sightings.reduce(into: Set<String>()) { ids, sighting in
            ids.formUnion(catalog.clientIDs(forSessionNamed: sighting.clientInfoName, tokenName: sighting.tokenName, detected: detected))
        }
    }

    private func markJustConnected(_ id: String) {
        justConnectedClientIDs.insert(id)
        settleTasks[id]?.cancel()
        settleTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.justConnectedDuration)
            guard !Task.isCancelled else { return }
            self?.justConnectedClientIDs.remove(id)
            self?.settleTasks[id] = nil
        }
    }

    private func perform(_ kind: MCPClientActionKind, on id: String) async -> MCPClientActionOutcome {
        guard let catalog,
              let row = row(id: id),
              let client = catalog.client(id: id),
              let spec = client.spec(for: .macos),
              spec.unsupported == nil
        else { return .unavailable }
        if case .running? = activities[id] { return .unavailable }
        if kind != .remove, row.config.isUserChoice { return .unavailable }
        // A disk image or a translocated copy is gone after eject or relaunch, so a client set up for it breaks.
        if kind != .remove, isAppOnReadOnlyVolume { return .refusedReadOnlyVolume }

        let route: MCPClientRoute? = switch kind {
        case .install: row.installRoute
        case .update: row.updateRoute
        case .remove: row.removeRoute
        }
        guard let route, route != .copy else { return .unavailable }

        activities[id] = .running(kind)
        let outcome: MCPClientActionOutcome
        do {
            outcome = try await run(kind, route: route, client: client, spec: spec, catalog: catalog)
        } catch let failure as MCPClientActionFailure {
            outcome = .failed(message: failure.message, output: failure.output)
        } catch {
            outcome = .failed(
                message: Self.message(for: error, fileName: row.configFileName ?? row.name),
                output: Self.technicalDetail(for: error)
            )
        }

        switch outcome {
        case let .failed(message, output):
            activities[id] = .failed(kind, message: message, output: output)
            Self.logger.error("A client setup action failed for \(id, privacy: .public)")
        case .handedOff:
            activities[id] = .handedOff
        case .done, .refusedReadOnlyVolume, .unavailable:
            activities[id] = nil
        }
        await refresh()
        return outcome
    }

    private func run(
        _ kind: MCPClientActionKind,
        route: MCPClientRoute,
        client: MCPClientDefinition,
        spec: MCPClientPlatformSpec,
        catalog: MCPClientCatalog
    ) async throws -> MCPClientActionOutcome {
        let renderer = MCPTemplateRenderer(serverName: catalog.serverName, target: .stdio(command: context.bridgePath))
        switch route {
        case .deeplink(let scheme):
            guard let template = spec.deeplinkTemplate(scheme: scheme) else { return .unavailable }
            let url = try renderer.url(template, entry: try renderer.entry(spec))
            guard url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame else { return .unavailable }
            try await context.workspace.open(url)
            return .handedOff

        case .cli(let binary):
            guard let cli = spec.cliInstall(binary: binary) else { return .unavailable }
            let scanner = MCPClientScanner(catalog: catalog, context: context)
            guard let executable = scanner.executable(named: binary) else {
                throw MCPClientActionFailure(
                    message: String(format: String(localized: "The %@ command is no longer installed."), binary),
                    output: nil
                )
            }
            let entry = try renderer.entry(spec)
            switch kind {
            case .install:
                try await runCommand(executable, try renderer.arguments(cli.add, entry: entry), isRemoval: false)
            case .update:
                if cli.update == .removeThenAdd, let remove = cli.remove {
                    try await runCommand(executable, try renderer.arguments(remove, entry: entry), isRemoval: true)
                }
                try await runCommand(executable, try renderer.arguments(cli.add, entry: entry), isRemoval: false)
            case .remove:
                guard let remove = cli.remove else { return .unavailable }
                try await runCommand(executable, try renderer.arguments(remove, entry: entry), isRemoval: true)
            }
            return .done(backupPath: nil)

        case .file:
            guard let location = catalog.location(for: client, platform: .macos),
                  location.isWritable,
                  location.format != .yaml
            else { return .unavailable }
            let url = URL(fileURLWithPath: context.expand(location.path))
            let name = catalog.serverName
            let writer = MCPConfigFileWriter()
            switch kind {
            case .install, .update:
                guard let template = spec.entry else { return .unavailable }
                let entry = try renderer.entry(spec)
                let result = try writer.update(url) { text in
                    try Self.updating(name, entry: entry, template: template, at: location, in: text ?? "")
                }
                return .done(backupPath: result.backupURL?.path)
            case .remove:
                guard FileManager.default.fileExists(atPath: url.path) else { return .done(backupPath: nil) }
                let result = try writer.update(url) { text in
                    try Self.removing(name, at: location, in: text ?? "")
                }
                return .done(backupPath: result.backupURL?.path)
            }

        case .copy:
            return .unavailable
        }
    }

    private func runCommand(_ executable: URL, _ arguments: [String], isRemoval: Bool) async throws {
        let result = try await runner.run(
            executable: executable,
            arguments: arguments,
            environment: context.processEnvironment()
        )
        guard result.exitCode != 0 else { return }
        // claude exits 1 for a server it does not have; for a removal that is the goal already reached.
        if isRemoval, Self.reportsMissingEntry(result.output) { return }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        throw MCPClientActionFailure(
            message: String(
                format: String(localized: "The %@ command stopped with exit code %d."),
                executable.lastPathComponent,
                Int(result.exitCode)
            ),
            output: output.isEmpty ? nil : output
        )
    }

    nonisolated static func reportsMissingEntry(_ output: String) -> Bool {
        let text = output.lowercased()
        return ["no mcp server", "not found", "does not exist", "no such server"].contains { text.contains($0) }
    }

    nonisolated private static func updating(
        _ name: String,
        entry: JSONValue,
        template: JSONValue,
        at location: MCPConfigLocation,
        in text: String
    ) throws -> String {
        switch location.format {
        case .toml:
            try TOMLTableEditor.updating(name, entry: entry, template: template, at: location.keyPath, in: text)
        case .json, .jsonc, .yaml:
            try JSONCMemberEditor.updating(name, entry: entry, template: template, at: location.keyPath, in: text)
        }
    }

    nonisolated private static func removing(_ name: String, at location: MCPConfigLocation, in text: String) throws -> String {
        switch location.format {
        case .toml:
            try TOMLTableEditor.removing(name, at: location.keyPath, in: text)
        case .json, .jsonc, .yaml:
            try JSONCMemberEditor.removing(name, at: location.keyPath, in: text)
        }
    }

    nonisolated static func message(for error: Error, fileName: String) -> String {
        if let edit = error as? MCPConfigEditError {
            switch edit {
            case .invalidSyntax:
                return String(format: String(localized: "%@ could not be read as valid settings, so TablePro left it unchanged."), fileName)
            case .duplicateKey:
                return String(format: String(localized: "%@ names the same key twice, so TablePro left it unchanged."), fileName)
            case .notAnObject:
                return String(format: String(localized: "%@ has an unexpected shape where TablePro would add itself, so TablePro left it unchanged."), fileName)
            case .unsupportedShape:
                return String(format: String(localized: "%@ defines TablePro in a form TablePro cannot edit safely, so it left the file unchanged."), fileName)
            case .verificationFailed:
                return verificationFailedMessage(fileName)
            }
        }
        if let write = error as? MCPConfigWriteError {
            switch write {
            case .changedDuringWrite:
                return String(format: String(localized: "%@ kept changing while TablePro wrote it. Try again."), fileName)
            case .verificationFailed:
                return verificationFailedMessage(fileName)
            case .io:
                return String(format: String(localized: "TablePro could not write %@."), fileName)
            }
        }
        if error is MCPTemplateError {
            return String(localized: "TablePro's client list has a setup for this client that it cannot fill in.")
        }
        return error.localizedDescription
    }

    nonisolated static func technicalDetail(for error: Error) -> String? {
        guard case .io(let detail)? = error as? MCPConfigWriteError else { return nil }
        return detail
    }

    nonisolated private static func verificationFailedMessage(_ fileName: String) -> String {
        String(format: String(localized: "TablePro could not confirm its change to %@. Check the file before you try again."), fileName)
    }
}
