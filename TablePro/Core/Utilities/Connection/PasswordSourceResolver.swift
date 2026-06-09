//
//  PasswordSourceResolver.swift
//  TablePro
//

import Foundation
import os

/// Resolves a connection password from an external source declared in connections.json.
/// File and command sources require a non-sandboxed build; TablePro ships with the hardened
/// runtime and no App Sandbox, so spawning a process and reading arbitrary files is allowed.
enum PasswordSourceResolver {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PasswordSourceResolver")

    private static let commandTimeoutSeconds: UInt64 = 30
    private static let maxOutputBytes = 1_048_576

    enum ResolutionError: LocalizedError {
        case fileNotFound(path: String)
        case fileUnreadable(path: String)
        case environmentVariableNotSet(name: String)
        case commandFailed(exitCode: Int32, stderr: String)
        case commandTimedOut
        case outputTooLarge
        case emptyPassword

        var errorDescription: String? {
            switch self {
            case let .fileNotFound(path):
                return String(format: String(localized: "Password file not found: %@"), path)
            case let .fileUnreadable(path):
                return String(format: String(localized: "Could not read password file: %@"), path)
            case let .environmentVariableNotSet(name):
                return String(
                    format: String(localized: """
                    Environment variable %@ is not set in TablePro's environment. \
                    Apps launched from the Dock do not inherit shell exports. Launch TablePro \
                    from a terminal, or set the variable with launchctl setenv.
                    """),
                    name
                )
            case let .commandFailed(exitCode, stderr):
                let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if message.isEmpty {
                    return String(format: String(localized: "Password command failed with exit code %d"), exitCode)
                }
                return String(format: String(localized: "Password command failed (exit %d): %@"), exitCode, message)
            case .commandTimedOut:
                return String(localized: "Password command timed out after 30 seconds")
            case .outputTooLarge:
                return String(localized: "Password command produced too much output")
            case .emptyPassword:
                return String(localized: "The password source produced an empty password")
            }
        }
    }

    static func resolve(_ source: PasswordSource) async throws -> String {
        switch source {
        case let .file(path):
            return try resolveFile(path: path)
        case let .env(variable):
            return try resolveEnvironment(variable: variable)
        case let .command(shell):
            return try await resolveCommand(shell: shell, timeoutSeconds: commandTimeoutSeconds)
        }
    }

    private static func resolveFile(path: String) throws -> String {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw ResolutionError.fileNotFound(path: expandedPath)
        }
        warnIfPermissionsInsecure(path: expandedPath)
        guard let contents = try? String(contentsOfFile: expandedPath, encoding: .utf8) else {
            throw ResolutionError.fileUnreadable(path: expandedPath)
        }
        return try nonEmpty(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func resolveEnvironment(variable: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[variable] else {
            throw ResolutionError.environmentVariableNotSet(name: variable)
        }
        return try nonEmpty(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func resolveCommand(shell: String, timeoutSeconds: UInt64) async throws -> String {
        let output = try await Task.detached(priority: .userInitiated) { () throws -> String in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", shell]
            process.environment = augmentedEnvironment()
            process.standardInput = FileHandle.nullDevice

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutCollector = PipeDataCollector(maxBytes: maxOutputBytes)
            let stderrCollector = PipeDataCollector(maxBytes: maxOutputBytes)
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stdoutCollector.append(chunk)
                if stdoutCollector.overflowed, process.isRunning {
                    process.terminate()
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { stderrCollector.append(chunk) }
            }

            try process.run()

            let didTimeout = AtomicFlag()
            let timeoutTask = Task.detached {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                if process.isRunning {
                    didTimeout.set()
                    process.terminate()
                }
            }

            process.waitUntilExit()
            timeoutTask.cancel()

            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil

            let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            if !remainingStdout.isEmpty { stdoutCollector.append(remainingStdout) }
            let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            if !remainingStderr.isEmpty { stderrCollector.append(remainingStderr) }

            if stdoutCollector.overflowed {
                throw ResolutionError.outputTooLarge
            }
            if didTimeout.isSet {
                throw ResolutionError.commandTimedOut
            }
            if process.terminationStatus != 0 {
                throw ResolutionError.commandFailed(
                    exitCode: process.terminationStatus,
                    stderr: stderrCollector.string
                )
            }
            return stdoutCollector.string
        }.value

        guard !output.contains("\0") else {
            throw ResolutionError.emptyPassword
        }
        return try nonEmpty(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func augmentedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let toolPaths = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var pathComponents = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for toolPath in toolPaths where !pathComponents.contains(toolPath) {
            pathComponents.append(toolPath)
        }
        environment["PATH"] = pathComponents.joined(separator: ":")
        return environment
    }

    private static func warnIfPermissionsInsecure(path: String) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let permissions = attributes[.posixPermissions] as? Int else {
            return
        }
        if permissions & 0o077 != 0 {
            logger.warning("Password file is group or world accessible; restrict it with chmod 600")
        }
    }

    private static func nonEmpty(_ password: String) throws -> String {
        guard !password.isEmpty else {
            throw ResolutionError.emptyPassword
        }
        return password
    }
}

private final class PipeDataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    private var data = Data()
    private var didOverflow = false

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = maxBytes - data.count
        guard remaining > 0 else {
            didOverflow = true
            return
        }
        if chunk.count > remaining {
            data.append(chunk.prefix(remaining))
            didOverflow = true
        } else {
            data.append(chunk)
        }
    }

    var overflowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didOverflow
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
