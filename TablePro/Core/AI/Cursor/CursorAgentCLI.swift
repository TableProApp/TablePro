//
//  CursorAgentCLI.swift
//  TablePro
//

import Foundation

enum CursorAgentError: Error, LocalizedError {
    case notInstalled
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return String(localized: "The Cursor CLI is not installed. Install it, then sign in.")
        case .launchFailed(let detail):
            return String(format: String(localized: "Cursor CLI failed: %@"), detail)
        }
    }
}

struct CursorAgentCLI: Sendable {
    static let installCommand = "curl https://cursor.com/install -fsS | bash"

    private static let process = AgentCLIProcess(label: "agent")

    static var discovery: AgentCLIDiscovery {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return AgentCLIDiscovery(
            candidatePaths: [
                "\(home)/.local/bin/agent",
                "/usr/local/bin/agent",
                "/opt/homebrew/bin/agent"
            ],
            preferredPathDirectories: [
                "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                "/usr/bin", "/bin", "/usr/sbin", "/sbin"
            ]
        )
    }

    static func executableURL() -> URL? {
        discovery.resolveExecutable(override: nil)
    }

    var isInstalled: Bool { Self.executableURL() != nil }

    func run(_ arguments: [String]) async throws -> (code: Int32, output: String) {
        do {
            return try await Self.process.run(try Self.makeLaunch(arguments))
        } catch {
            throw Self.translate(error)
        }
    }

    func stream(_ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        do {
            return Self.process.streamLines(try Self.makeLaunch(arguments))
        } catch {
            let translated = Self.translate(error)
            return AsyncThrowingStream { $0.finish(throwing: translated) }
        }
    }

    private static func makeLaunch(_ arguments: [String]) throws -> AgentCLILaunch {
        guard let executable = executableURL() else { throw CursorAgentError.notInstalled }
        return AgentCLILaunch(
            executable: executable,
            arguments: arguments,
            environment: discovery.makeEnvironment()
        )
    }

    private static func translate(_ error: Error) -> Error {
        switch error {
        case AgentCLIError.notInstalled:
            return CursorAgentError.notInstalled
        case AgentCLIError.launchFailed(let detail):
            return CursorAgentError.launchFailed(detail)
        default:
            return error
        }
    }
}
