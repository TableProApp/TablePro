import Combine
import Foundation
@testable import TablePro
import TableProMCPClients

enum MCPClientSetupFixture {
    static let catalogJSON = #"""
    {
      "schemaVersion": 1,
      "serverName": "tablepro",
      "configs": {
        "editor": { "macos": { "path": "~/.editor/mcp.json", "format": "json", "keyPath": ["mcpServers"] } },
        "agent": {
          "macos": { "path": "~/.agent.json", "format": "json", "keyPath": ["mcpServers"], "writable": false, "otherScopes": [["projects", "*", "mcpServers"]] }
        },
        "shared": { "macos": { "path": "~/.shared/config.toml", "format": "toml", "keyPath": ["mcp_servers"] } }
      },
      "clients": [
        {
          "id": "editor", "name": "Editor", "icon": "editor", "config": "editor",
          "clientInfo": { "names": ["editor-client"], "prefixes": [] },
          "macos": {
            "detect": [{ "bundleId": "com.example.editor" }, { "path": "~/.editor" }],
            "entry": { "command": "{command}", "args": [], "tools": ["*"] },
            "install": [
              { "kind": "deeplink", "scheme": "editor", "url": "editor://install?name={name}&config={entry|json|base64|uri}" },
              { "kind": "cli", "binary": "editor", "add": ["mcp", "add", "{name}", "--", "{command}"], "remove": ["mcp", "remove", "{name}"], "update": "add" },
              { "kind": "file" }
            ],
            "applies": "live"
          },
          "linux": {
            "entry": { "url": "{url}", "headers": { "Authorization": "{authorization}" } },
            "install": [{ "kind": "file" }]
          }
        },
        {
          "id": "agent", "name": "Agent", "icon": "agent", "config": "agent",
          "clientInfo": { "names": ["agent-cli"], "prefixes": [] },
          "macos": {
            "detect": [{ "binary": "agent", "paths": ["~/bin/agent"] }],
            "entry": { "type": "stdio", "command": "{command}", "args": [] },
            "install": [
              {
                "kind": "cli", "binary": "agent",
                "add": ["mcp", "add", "--scope", "user", "{name}", "--", "{command}"],
                "remove": ["mcp", "remove", "--scope", "user", "{name}"],
                "update": "removeThenAdd"
              }
            ],
            "applies": "newSession"
          },
          "linux": {
            "entry": { "type": "http", "url": "{url}", "headers": { "Authorization": "{authorization}" } },
            "install": [
              { "kind": "cli", "binary": "agent", "add": ["mcp", "add", "--transport", "http", "{name}", "{url}", "--header", "Authorization: {authorization}"] }
            ]
          }
        },
        {
          "id": "desk", "name": "Desk", "icon": "desk", "config": "shared",
          "clientInfo": { "names": ["shared-client"], "prefixes": [] },
          "macos": {
            "detect": [{ "bundleId": "com.example.desk" }],
            "entry": { "command": "{command}", "args": [] },
            "install": [{ "kind": "file" }],
            "applies": "restartApp"
          }
        },
        {
          "id": "term", "name": "Term", "icon": "term", "config": "shared",
          "clientInfo": { "names": ["shared-client"], "prefixes": [] },
          "macos": {
            "detect": [{ "path": "~/.shared" }],
            "entry": { "command": "{command}", "args": [] },
            "install": [{ "kind": "file" }],
            "applies": "newSession"
          }
        },
        {
          "id": "remote", "name": "Remote", "icon": "remote", "config": null,
          "clientInfo": { "names": [], "prefixes": [] },
          "macos": { "detect": [{ "bundleId": "com.example.remote" }], "unsupported": "remoteOnly" }
        },
        {
          "id": "penguin", "name": "Penguin", "icon": "penguin", "config": "editor",
          "clientInfo": { "names": ["penguin"], "prefixes": [] },
          "linux": { "detect": [{ "path": "~/.penguin" }], "entry": { "url": "{url}" }, "install": [{ "kind": "file" }] }
        }
      ]
    }
    """#

    static func catalog() throws -> MCPClientCatalog {
        try MCPClientCatalog.decode(Data(catalogJSON.utf8))
    }
}

// A home folder of its own, so no test reads or writes the real one.
final class MCPClientTestHome {
    let root: URL
    let bridge: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-clients-\(UUID().uuidString.prefix(8))", isDirectory: true)
        bridge = root.appendingPathComponent("Applications/TablePro.app/Contents/MacOS/tablepro-mcp")
        try FileManager.default.createDirectory(at: bridge.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bridge.path, contents: Data())
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var path: String { root.path }

    func url(_ relative: String) -> URL {
        root.appendingPathComponent(relative)
    }

    func write(_ relative: String, _ text: String) throws {
        let file = url(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func read(_ relative: String) -> String? {
        try? String(contentsOf: url(relative), encoding: .utf8)
    }

    func makeFolder(_ relative: String) throws {
        try FileManager.default.createDirectory(at: url(relative), withIntermediateDirectories: true)
    }

    func makeExecutable(_ relative: String) throws {
        try write(relative, "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url(relative).path)
    }

    func remove(_ relative: String) throws {
        try FileManager.default.removeItem(at: url(relative))
    }

    func context(workspace: FakeMCPClientWorkspace) -> MCPClientSetupContext {
        let home = path
        return MCPClientSetupContext(
            home: home,
            environment: [:],
            bridgePath: bridge.path,
            workspace: workspace,
            isExecutable: { $0.hasPrefix(home + "/") && FileManager.default.isExecutableFile(atPath: $0) }
        )
    }
}

final class FakeMCPClientWorkspace: MCPClientWorkspace, @unchecked Sendable {
    private let lock = NSLock()
    private let installedBundleIDs: Set<String>
    private let handledSchemes: Set<String>
    private var openedURLs: [URL] = []

    init(installedBundleIDs: Set<String> = [], handledSchemes: Set<String> = []) {
        self.installedBundleIDs = installedBundleIDs
        self.handledSchemes = handledSchemes
    }

    var opened: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return openedURLs
    }

    func applicationURL(forBundleIdentifier identifier: String) -> URL? {
        installedBundleIDs.contains(identifier) ? URL(fileURLWithPath: "/Applications/\(identifier).app") : nil
    }

    func applicationURL(toOpen url: URL) -> URL? {
        guard let scheme = url.scheme, handledSchemes.contains(scheme) else { return nil }
        return URL(fileURLWithPath: "/Applications/\(scheme).app")
    }

    func open(_ url: URL) async throws {
        lock.withLock { openedURLs.append(url) }
    }
}

final class FakeMCPClientRunner: MCPClientCommandRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let home: String?
    }

    private let lock = NSLock()
    private var replies: [MCPClientCommandResult]
    private var recorded: [Call] = []

    init(replies: [MCPClientCommandResult] = []) {
        self.replies = replies
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(executable: URL, arguments: [String], environment: [String: String]) async throws -> MCPClientCommandResult {
        lock.withLock {
            recorded.append(Call(executable: executable.path, arguments: arguments, home: environment["HOME"]))
            return replies.isEmpty ? MCPClientCommandResult(exitCode: 0, output: "") : replies.removeFirst()
        }
    }
}

@MainActor
final class MCPClientAnnouncements {
    private(set) var messages: [String] = []

    func record(_ message: String) {
        messages.append(message)
    }
}

@MainActor
struct MCPClientServiceHarness {
    let service: MCPClientSetupService
    let sessions: PassthroughSubject<[MCPClientSessionSighting], Never>
    let announcements: MCPClientAnnouncements

    init(
        home: MCPClientTestHome,
        workspace: FakeMCPClientWorkspace = FakeMCPClientWorkspace(),
        runner: FakeMCPClientRunner = FakeMCPClientRunner(),
        isAppOnReadOnlyVolume: Bool = false
    ) throws {
        let sessions = PassthroughSubject<[MCPClientSessionSighting], Never>()
        let announcements = MCPClientAnnouncements()
        self.sessions = sessions
        self.announcements = announcements
        service = MCPClientSetupService(
            catalog: try MCPClientSetupFixture.catalog(),
            context: home.context(workspace: workspace),
            runner: runner,
            isAppOnReadOnlyVolume: isAppOnReadOnlyVolume,
            sessions: sessions.eraseToAnyPublisher(),
            activations: Empty<Void, Never>().eraseToAnyPublisher(),
            announce: { announcements.record($0) }
        )
    }
}
