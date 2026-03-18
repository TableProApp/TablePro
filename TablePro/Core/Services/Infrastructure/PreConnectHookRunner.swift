//
//  PreConnectHookRunner.swift
//  TablePro
//

import Foundation
import os

/// Runs a shell script before establishing a database connection.
/// Non-zero exit aborts the connection with an error.
enum PreConnectHookRunner {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PreConnectHookRunner")

    enum HookError: LocalizedError {
        case scriptFailed(exitCode: Int32, stderr: String)
        case timeout

        var errorDescription: String? {
            switch self {
            case let .scriptFailed(exitCode, stderr):
                let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if message.isEmpty {
                    return String(localized: "Pre-connect script failed with exit code \(exitCode)")
                }
                return String(localized: "Pre-connect script failed (exit \(exitCode)): \(message)")
            case .timeout:
                return String(localized: "Pre-connect script timed out after 10 seconds")
            }
        }
    }

    /// Run a shell script before connecting. Throws on non-zero exit or timeout.
    /// Executes on a background thread to avoid blocking the MainActor.
    static func run(script: String, environment: [String: String]? = nil) async throws {
        logger.info("Running pre-connect script")

        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", script]

            var env = ProcessInfo.processInfo.environment
            if let environment {
                for (key, value) in environment {
                    env[key] = value
                }
            }
            process.environment = env

            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = FileHandle.nullDevice

            // Drain stderr on a background thread to prevent pipe deadlock.
            // If the child writes >64KB to stderr without the parent reading,
            // the pipe buffer fills and the child blocks on write — deadlocking
            // with waitUntilExit() on the parent side.
            let stderrCollector = StderrCollector()
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty {
                    stderrCollector.append(chunk)
                }
            }

            try process.run()

            // 10-second timeout on a separate detached task
            let timeoutTask = Task.detached {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                if process.isRunning {
                    process.terminate()
                }
            }

            process.waitUntilExit()
            timeoutTask.cancel()

            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let stderr = stderrCollector.result

            if process.terminationReason == .uncaughtSignal {
                throw HookError.timeout
            }

            if process.terminationStatus != 0 {
                throw HookError.scriptFailed(exitCode: process.terminationStatus, stderr: stderr)
            }
        }.value

        logger.info("Pre-connect script completed successfully")
    }
}

/// Thread-safe collector for stderr output from a child process.
private final class StderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var result: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
