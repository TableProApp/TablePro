//
//  AgentCLIProcess.swift
//  TablePro
//

import Foundation
import os
import TableProProcess

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
        let process: Process
        do {
            process = try Self.makeProcess(launch)
        } catch {
            throw AgentCLIError.launchFailed(error.localizedDescription)
        }
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
            let process: Process
            do {
                process = try Self.makeProcess(launch)
            } catch {
                continuation.finish(throwing: AgentCLIError.launchFailed(error.localizedDescription))
                return
            }
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let label = self.label
            // Not FileHandle.bytes: Foundation runs every AsyncBytes read on one serial queue, so a quiet
            // stderr or an idle language server holds the stdout read until the tool exits.
            let stderrReader = PipeReader(stderr.fileHandleForReading)
            stderrReader.startDeliveringLines { line in
                guard !line.isEmpty else { return }
                Self.logger.error("\(label, privacy: .public) stderr: \(line, privacy: .private)")
            }

            do {
                try process.run()
            } catch {
                stderrReader.stop()
                continuation.finish(throwing: AgentCLIError.launchFailed(error.localizedDescription))
                return
            }

            let stdoutReader = PipeReader(stdout.fileHandleForReading)
            stdoutReader.startDeliveringLines(
                { line in
                    guard !line.isEmpty else { return }
                    continuation.yield(line)
                },
                onEnd: { continuation.finish() }
            )

            continuation.onTermination = { _ in
                stdoutReader.stop()
                stderrReader.stop()
                Self.terminate(process, label: label)
            }
        }
    }

    private static func makeProcess(_ launch: AgentCLILaunch) throws -> Process {
        try ProcessLauncher.process(for: ProcessCommand(
            executable: launch.executable,
            arguments: launch.arguments,
            environment: launch.environment,
            currentDirectory: launch.currentDirectory
        ))
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
