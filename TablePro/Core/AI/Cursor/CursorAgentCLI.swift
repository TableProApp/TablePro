//
//  CursorAgentCLI.swift
//  TablePro
//

import Foundation
import os

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

    private static let logger = Logger(subsystem: "com.TablePro", category: "CursorAgentCLI")

    static func executableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appending(path: ".local/bin/agent"),
            URL(fileURLWithPath: "/usr/local/bin/agent"),
            URL(fileURLWithPath: "/opt/homebrew/bin/agent")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    var isInstalled: Bool { Self.executableURL() != nil }

    func run(_ arguments: [String]) async throws -> (code: Int32, output: String) {
        guard let executable = Self.executableURL() else { throw CursorAgentError.notInstalled }
        let process = Process()
        Self.configure(process, executable: executable, arguments: arguments)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = stdout
        Self.logger.debug("Running agent \(arguments.first ?? "", privacy: .public)")
        do {
            try process.run()
        } catch {
            throw CursorAgentError.launchFailed(error.localizedDescription)
        }
        let data = try await Task.detached {
            try stdout.fileHandleForReading.readToEnd() ?? Data()
        }.value
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    func stream(_ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let executable = Self.executableURL() else {
                continuation.finish(throwing: CursorAgentError.notInstalled)
                return
            }
            let process = Process()
            Self.configure(process, executable: executable, arguments: arguments)
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let stderrReader = Task {
                do {
                    for try await line in stderr.fileHandleForReading.bytes.lines where !line.isEmpty {
                        Self.logger.error("agent stderr: \(line, privacy: .public)")
                    }
                } catch {}
            }
            process.terminationHandler = { proc in
                Self.logger.debug("agent exited code=\(proc.terminationStatus)")
            }

            Self.logger.debug("Streaming agent (\(arguments.count) args)")
            do {
                try process.run()
            } catch {
                stderrReader.cancel()
                continuation.finish(throwing: CursorAgentError.launchFailed(error.localizedDescription))
                return
            }

            let reader = Task {
                do {
                    for try await line in stdout.fileHandleForReading.bytes.lines {
                        if Task.isCancelled { break }
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                reader.cancel()
                stderrReader.cancel()
                if process.isRunning { process.terminate() }
            }
        }
    }

    private static func configure(_ process: Process, executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.environment = makeEnvironment()
    }

    private static func makeEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let preferred = [
            "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ]
        let current = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        environment["PATH"] = (preferred + current)
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
        return environment
    }
}
