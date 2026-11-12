import Foundation
import TableProMCPClients

struct MCPClientSetupContext: Sendable {
    let home: String
    let environment: [String: String]
    let bridgePath: String
    let workspace: any MCPClientWorkspace
    let isExecutable: @Sendable (String) -> Bool

    init(
        home: String,
        environment: [String: String],
        bridgePath: String,
        workspace: any MCPClientWorkspace = SystemMCPClientWorkspace(),
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.home = home
        self.environment = environment
        self.bridgePath = bridgePath
        self.workspace = workspace
        self.isExecutable = isExecutable
    }

    // A sandboxed run reads and writes client settings in a home inside the sandbox, never the real one.
    static func live(storage: AppStorageEnvironment = .shared, bundle: Bundle = .main) -> MCPClientSetupContext {
        let processEnvironment = ProcessInfo.processInfo.environment
        let bridgePath = bundle.bundleURL.appendingPathComponent("Contents/MacOS/tablepro-mcp").path
        guard storage.isIsolated else {
            return MCPClientSetupContext(
                home: NSHomeDirectory(),
                environment: processEnvironment,
                bridgePath: bridgePath
            )
        }
        return MCPClientSetupContext(
            home: storage.supportDirectory.appendingPathComponent("ClientHome", isDirectory: true).path,
            environment: processEnvironment["PATH"].map { ["PATH": $0] } ?? [:],
            bridgePath: bridgePath
        )
    }

    var searchDirectories: [String] {
        [
            "\(home)/.local/bin",
            "\(home)/.claude/local",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/.opencode/bin",
            "/usr/bin",
            "/bin"
        ] + AgentCLIDiscovery.nodeVersionManagerDirectories(home: home)
    }

    func expand(_ path: String) -> String {
        MCPPathExpander.expand(path, home: home, environment: environment)
    }

    func displayPath(_ path: String) -> String {
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    // A GUI app gets launchd's PATH, and a node-based CLI needs node on it.
    func processEnvironment() -> [String: String] {
        AgentCLIDiscovery(candidatePaths: [], preferredPathDirectories: searchDirectories)
            .makeEnvironment(base: environment, adding: ["HOME": home])
    }

    func executable(named name: String, catalogPaths: [String]) -> URL? {
        var seen = Set<String>()
        let candidates = (catalogPaths.map(expand) + searchDirectories.map { "\($0)/\(name)" })
            .filter { seen.insert($0).inserted }
        return AgentCLIDiscovery(
            candidatePaths: candidates,
            preferredPathDirectories: searchDirectories,
            isExecutable: isExecutable
        ).resolveExecutable(override: nil)
    }
}
