//
//  AgentCLIProcess.swift
//  TablePro
//

import Foundation
import os
import TableProProcess
import TableProUtilities

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

// Never FileHandle.bytes: every AsyncBytes read shares one serial queue, so a quiet pipe stalls every other read.
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
        // Read while the child runs: one that fills the pipe never exits.
        let output = OSAllocatedUnfairLock(initialState: Data())
        let reader = PipeReader(combined.fileHandleForReading)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    reader.stopAtEndOfFile()
                    let data = output.withLock { $0 }
                    continuation.resume(
                        returning: (finished.terminationStatus, String(data: data, encoding: .utf8) ?? "")
                    )
                }
                reader.start { chunk in
                    output.withLock { $0.append(chunk) }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    reader.stop()
                    continuation.resume(throwing: AgentCLIError.launchFailed(error.localizedDescription))
                    return
                }
                // A cancel that landed before launch found nothing running to stop.
                if Task.isCancelled {
                    Self.terminate(process, label: label)
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
            let stdoutLines = OSAllocatedUnfairLock(initialState: LineSplitter())
            let stderrLines = OSAllocatedUnfairLock(initialState: LineSplitter())
            let stdoutReader = PipeReader(stdout.fileHandleForReading)
            let stderrReader = PipeReader(stderr.fileHandleForReading)

            continuation.onTermination = { _ in
                Self.terminate(process, label: label)
                stdoutReader.stop()
                stderrReader.stop(drainingUpTo: DescriptorRead.pipeCapacity)
                Self.logStderr(stderrLines.withLock { $0.finish() }, label: label)
            }

            stderrReader.start { chunk in
                Self.logStderr(stderrLines.withLock { $0.append(chunk) }, label: label)
            } atEnd: { _ in
                Self.logStderr(stderrLines.withLock { $0.finish() }, label: label)
            }
            stdoutReader.start { chunk in
                for line in stdoutLines.withLock({ $0.append(chunk) }) {
                    continuation.yield(line)
                }
            } atEnd: { failure in
                for line in stdoutLines.withLock({ $0.finish() }) {
                    continuation.yield(line)
                }
                continuation.finish(throwing: failure)
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: AgentCLIError.launchFailed(error.localizedDescription))
            }
        }
    }

    private static func logStderr(_ lines: [String], label: String) {
        for line in lines {
            logger.error("\(label, privacy: .public) stderr: \(line, privacy: .private)")
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

extension AgentCLIProcess {
    // LF alone ends a line: stream-json text can hold a raw U+2028, which FileHandle's `lines` also splits on.
    struct LineSplitter: Sendable {
        private var partial = Data()

        mutating func append(_ chunk: Data) -> [String] {
            var lines: [String] = []
            var lineStart = chunk.startIndex
            while let newline = chunk[lineStart...].firstIndex(of: 0x0A) {
                partial.append(chunk[lineStart ..< newline])
                if let line = Self.decode(partial) {
                    lines.append(line)
                }
                partial.removeAll(keepingCapacity: true)
                lineStart = chunk.index(after: newline)
            }
            partial.append(chunk[lineStart...])
            return lines
        }

        mutating func finish() -> [String] {
            defer { partial = Data() }
            return Self.decode(partial).map { [$0] } ?? []
        }

        private static func decode(_ bytes: Data) -> String? {
            let line = bytes.last == 0x0D ? bytes.dropLast() : bytes
            guard !line.isEmpty else { return nil }
            return String(bytes: line, encoding: .utf8)
        }
    }
}
