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

    enum ResolutionError: LocalizedError, Equatable {
        case fileNotFound(path: String)
        case fileUnreadable(path: String)
        case environmentVariableNotSet(name: String)
        case commandFailed(exitCode: Int32, stderr: String)
        case commandTimedOut
        case outputTooLarge
        case emptyPassword
        case invalidSecretJson
        case jsonKeyNotFound(key: String)
        case storeNotTrusted
        case profileStoreNotTrusted
        case signsInWithLease

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
            case .invalidSecretJson:
                return String(localized: "The secret manager did not return valid JSON.")
            case let .jsonKeyNotFound(key):
                return String(format: String(localized: "Key %@ was not found in the secret JSON."), key)
            case .storeNotTrusted:
                return String(localized: """
                    Your connections file was changed outside TablePro, so this connection's \
                    password source was not run. Open the connection and save it again to \
                    confirm the change.
                    """)
            case .profileStoreNotTrusted:
                return String(localized: """
                    Your credential profiles file was changed outside TablePro, so this profile's \
                    password source was not run.
                    """)
            case .signsInWithLease:
                return String(localized: "A Vault database role signs in with a username too, so it cannot stand in for a password alone.")
            }
        }
    }

    // A test reports what the source returns right now, so it neither reads nor fills the reuse cache.
    // A Vault role test may open the browser to sign in, and revokes the lease it was given at once.
    static func test(_ source: PasswordSource, for context: ConnectionScriptContext) async throws -> String {
        if case .vaultDatabaseRole(let role) = source {
            let signIn = try await VaultDatabaseCredentials.shared.signIn(role, interactive: true)
            signIn.lease?.release()
            return signIn.username.map { "\($0) / \(signIn.password)" } ?? signIn.password
        }
        return try await resolve(source.withoutReuse, for: context)
    }

    static func resolve(
        _ source: PasswordSource,
        for context: ConnectionScriptContext? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cache: PasswordCommandCache = .shared
    ) async throws -> String {
        switch source {
        case let .file(path):
            return try resolveFile(path: path)
        case let .env(variable):
            return try resolveEnvironment(variable: variable, in: environment)
        case let .command(shell, reuseSeconds):
            let command = context?.substitutingPlaceholders(in: shell) ?? shell
            let commandEnvironment = context?.environment ?? [:]
            let run = {
                try await resolveCommand(
                    shell: command,
                    environment: commandEnvironment,
                    timeoutSeconds: commandTimeoutSeconds
                )
            }
            guard let context, let reuseSeconds = PasswordSource.validReuseSeconds(reuseSeconds) else {
                return try await run()
            }
            return try await cache.password(
                connectionId: context.connectionId,
                command: command,
                environment: commandEnvironment,
                lifetime: .seconds(reuseSeconds),
                resolve: run
            )
        case .onePassword, .vault:
            return try await resolveExternalTool(source)
        case let .awsSecretsManager(_, jsonKey):
            let secret = try await resolveExternalTool(source)
            guard let jsonKey, !jsonKey.isEmpty else { return secret }
            return try extractJsonField(jsonKey, from: secret)
        case .vaultDatabaseRole:
            throw ResolutionError.signsInWithLease
        }
    }

    /// The shell command that fetches a secret for CLI-backed sources, or nil for the local sources.
    /// Arguments are single-quoted so a reference can never break out into shell injection.
    static func externalCommand(for source: PasswordSource) -> String? {
        switch source {
        case .file, .env, .command, .vaultDatabaseRole:
            return nil
        case let .onePassword(reference):
            return "op read --no-newline \(shellQuote(reference))"
        case let .vault(path, field):
            return "vault kv get -field=\(shellQuote(field)) \(shellQuote(path))"
        case let .awsSecretsManager(secretId, _):
            return "aws secretsmanager get-secret-value --secret-id \(shellQuote(secretId)) "
                + "--query SecretString --output text"
        }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''", options: .literal) + "'"
    }

    static func extractJsonField(_ key: String, from json: String) throws -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResolutionError.invalidSecretJson
        }
        guard let value = object[key] else {
            throw ResolutionError.jsonKeyNotFound(key: key)
        }
        if let stringValue = value as? String {
            return try nonEmpty(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let number = value as? NSNumber {
            return try nonEmpty(number.stringValue)
        }
        throw ResolutionError.invalidSecretJson
    }

    private static func resolveExternalTool(_ source: PasswordSource) async throws -> String {
        guard let command = externalCommand(for: source) else {
            throw ResolutionError.emptyPassword
        }
        return try await resolveCommand(shell: command, timeoutSeconds: commandTimeoutSeconds)
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

    private static func resolveEnvironment(variable: String, in environment: [String: String]) throws -> String {
        guard let value = environment[variable] else {
            throw ResolutionError.environmentVariableNotSet(name: variable)
        }
        return try nonEmpty(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func resolveCommand(
        shell: String,
        environment: [String: String] = [:],
        timeoutSeconds: UInt64,
        clock: any Clock<Duration> = ContinuousClock()
    ) async throws -> String {
        let output = try await Task.detached(priority: .userInitiated) { () async throws -> String in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", shell]
            process.environment = CLIToolEnvironment.augmented().merging(environment) { _, connection in connection }
            process.standardInput = FileHandle.nullDevice

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutCollector = PipeDataCollector(maxBytes: maxOutputBytes)
            let stderrCollector = PipeDataCollector(maxBytes: maxOutputBytes)
            try process.run()

            let drainGroup = DispatchGroup()
            let drainQueue = DispatchQueue(label: "com.TablePro.PasswordSourceResolver.pipe-drain", attributes: .concurrent)
            drainPipe(
                stdoutPipe.fileHandleForReading,
                into: stdoutCollector,
                using: drainGroup,
                queue: drainQueue
            ) {
                if process.isRunning {
                    process.terminate()
                }
            }
            drainPipe(
                stderrPipe.fileHandleForReading,
                into: stderrCollector,
                using: drainGroup,
                queue: drainQueue
            )

            let didTimeout = AtomicFlag()
            let timeoutTask = Task.detached {
                try await clock.sleep(for: .seconds(timeoutSeconds))
                if process.isRunning {
                    didTimeout.set()
                    process.terminate()
                }
            }

            process.waitUntilExit()
            timeoutTask.cancel()
            await withCheckedContinuation { continuation in
                drainGroup.notify(queue: drainQueue) { continuation.resume() }
            }

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

    private static func drainPipe(
        _ handle: FileHandle,
        into collector: PipeDataCollector,
        using group: DispatchGroup,
        queue: DispatchQueue,
        onOverflow: (() -> Void)? = nil
    ) {
        group.enter()
        queue.async {
            defer { group.leave() }
            while true {
                let chunk = handle.readData(ofLength: 8_192)
                guard !chunk.isEmpty else { return }
                collector.append(chunk)
                if collector.overflowed {
                    onOverflow?()
                }
            }
        }
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
