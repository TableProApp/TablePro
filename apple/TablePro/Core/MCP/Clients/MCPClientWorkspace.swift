import AppKit
import Foundation

protocol MCPClientWorkspace: Sendable {
    func applicationURL(forBundleIdentifier identifier: String) -> URL?
    func applicationURL(toOpen url: URL) -> URL?
    func open(_ url: URL) async throws
}

struct SystemMCPClientWorkspace: MCPClientWorkspace {
    func applicationURL(forBundleIdentifier identifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
    }

    func applicationURL(toOpen url: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    // Only a catalog deeplink reaches here, and only after a handler app was found for its scheme.
    func open(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

struct MCPClientCommandResult: Equatable, Sendable {
    let exitCode: Int32
    let output: String
}

protocol MCPClientCommandRunning: Sendable {
    func run(executable: URL, arguments: [String], environment: [String: String]) async throws -> MCPClientCommandResult
}

enum MCPClientCommandError: Error, LocalizedError, Equatable {
    case timedOut(command: String, seconds: Int)

    var errorDescription: String? {
        switch self {
        case let .timedOut(command, seconds):
            String(format: String(localized: "The %@ command did not finish within %d seconds."), command, seconds)
        }
    }
}

struct AgentCLICommandRunner: MCPClientCommandRunning {
    var timeoutSeconds = 60

    func run(executable: URL, arguments: [String], environment: [String: String]) async throws -> MCPClientCommandResult {
        let process = AgentCLIProcess(label: executable.lastPathComponent)
        let launch = AgentCLILaunch(executable: executable, arguments: arguments, environment: environment)
        let limit = timeoutSeconds
        return try await withThrowingTaskGroup(of: MCPClientCommandResult?.self) { group in
            group.addTask {
                let finished = try await process.run(launch)
                return MCPClientCommandResult(exitCode: finished.code, output: finished.output)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(limit))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let result = first else {
                throw MCPClientCommandError.timedOut(command: executable.lastPathComponent, seconds: limit)
            }
            return result
        }
    }
}
