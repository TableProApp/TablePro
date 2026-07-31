//
//  AgentCLIProcess.swift
//  TablePro
//

import Foundation
import os

enum AgentCLIError: Error, LocalizedError {
    case notInstalled(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let tool):
            return String(format: String(localized: "The %@ command line tool is not installed."), tool)
        case .launchFailed(let detail):
            return String(format: String(localized: "Command line tool failed: %@"), detail)
        }
    }
}

struct AgentCLILaunch: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let currentDirectory: URL?

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }
}

struct AgentCLIProcess: Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "AgentCLIProcess")
    private static let terminationGracePeriod: Duration = .milliseconds(750)

    let label: String

    func run(_ launch: AgentCLILaunch) async throws -> (code: Int32, output: String) {
        let process = Self.makeProcess(launch)
        let combined = Pipe()
        process.standardOutput = combined
        process.standardError = combined

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    let data = (try? combined.fileHandleForReading.readToEnd() ?? Data()) ?? Data()
                    continuation.resume(
                        returning: (finished.terminationStatus, String(data: data, encoding: .utf8) ?? "")
                    )
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: AgentCLIError.launchFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            Self.terminate(process, label: label)
        }
    }

    func streamLines(_ launch: AgentCLILaunch) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Self.makeProcess(launch)
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let label = self.label
            let stderrDrain = Task {
                for try await line in stderr.fileHandleForReading.bytes.lines where !line.isEmpty {
                    Self.logger.error("\(label, privacy: .public) stderr: \(line, privacy: .public)")
                }
            }

            do {
                try process.run()
            } catch {
                stderrDrain.cancel()
                continuation.finish(throwing: AgentCLIError.launchFailed(error.localizedDescription))
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
                stderrDrain.cancel()
                Self.terminate(process, label: label)
            }
        }
    }

    private static func makeProcess(_ launch: AgentCLILaunch) -> Process {
        let process = Process()
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.currentDirectoryURL = launch.currentDirectory
        process.standardInput = FileHandle.nullDevice
        return process
    }

    private static func terminate(_ process: Process, label: String) {
        guard process.isRunning else { return }
        let identifier = process.processIdentifier
        process.terminate()
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: terminationGracePeriod)
            guard process.isRunning else { return }
            logger.warning("\(label, privacy: .public) ignored SIGTERM, sending SIGKILL")
            kill(identifier, SIGKILL)
        }
    }
}
