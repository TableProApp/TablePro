//
//  BeancountPluginDriver+Backend.swift
//  BeancountDriverPlugin
//

import Foundation
import os

extension BeancountPluginDriver {
    internal static func resolveProjectionBackend(
        connectAttempt: BeancountConnectAttempt?
    ) throws -> BeancountBackend {
        try connectAttempt?.check()
        let preference = ProcessInfo.processInfo.environment["TABLEPRO_BEANCOUNT_BACKEND"]?.lowercased()
        switch preference {
        case "rledger", "rustledger":
            return .rledger(try rustledgerExecutablePath())
        case "python", "beancount":
            return .python(try pythonBeancountExecutablePath(connectAttempt: connectAttempt))
        default:
            if let rledgerPath = try optionalRustledgerExecutablePath() {
                return .rledger(rledgerPath)
            }
            if let pythonPath = try optionalPythonBeancountExecutablePath(connectAttempt: connectAttempt) {
                return .python(pythonPath)
            }
            throw BeancountDriverError.beancountBackendUnavailable(
                String(localized: "Beancount needs rledger or Python Beancount. Install one, or set TABLEPRO_RUSTLEDGER_BINARY or TABLEPRO_BEANCOUNT_PYTHON to its path.")
            )
        }
    }

    internal static func backendVersion(
        _ backend: BeancountBackend,
        connectAttempt: BeancountConnectAttempt?
    ) throws -> String {
        try connectAttempt?.check()
        let key = backendCacheKey(backend)
        if let cached = backendVersions.withLock({ $0[key] }) {
            return cached
        }
        let resolved = try resolvedBackendVersion(backend, connectAttempt: connectAttempt)
        try connectAttempt?.check()
        backendVersions.withLock { $0[key] = resolved }
        return resolved
    }

    internal static func rledgerQueryArguments(
        ledgerPath: String,
        query: String,
        connectAttempt: BeancountConnectAttempt? = nil
    ) throws -> [String] {
        try connectAttempt?.check()
        let rustledgerPath = try rustledgerExecutablePath()
        var arguments = ["query", "-f", "json", "--no-errors"]
        if try rledgerSupportsNoCache(executablePath: rustledgerPath, connectAttempt: connectAttempt) {
            arguments.append("--no-cache")
        }
        arguments.append(contentsOf: [ledgerPath, query])
        return arguments
    }

    internal static func runRledger(
        arguments: [String],
        connectAttempt: BeancountConnectAttempt? = nil
    ) throws -> Data {
        let rustledgerPath = try rustledgerExecutablePath()
        return try runProcess(
            executablePath: rustledgerPath,
            arguments: arguments,
            failureMessage: String(localized: "rustledger command failed"),
            connectAttempt: connectAttempt
        )
    }

    internal static func runProcess(
        executablePath: String,
        arguments: [String],
        failureMessage: String,
        allowsNonZeroExit: Bool = false,
        environment: [String: String] = [:],
        connectAttempt: BeancountConnectAttempt? = nil
    ) throws -> Data {
        let output = try BeancountProcessRunner.run(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            connectAttempt: connectAttempt
        )
        guard output.terminationStatus == 0 || allowsNonZeroExit else {
            let message = String(data: output.standardError, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let message, !message.isEmpty {
                throw BeancountDriverError.queryFailed(message)
            }
            throw BeancountDriverError.queryFailed(failureMessage)
        }

        return output.standardOutput
    }

    internal static func rustledgerExecutablePath() throws -> String {
        if let path = try optionalRustledgerExecutablePath() {
            return path
        }
        throw BeancountDriverError.beancountBackendUnavailable(
            String(localized: "BQL queries need rledger. Install rustledger so rledger is on PATH or Homebrew, or set TABLEPRO_RUSTLEDGER_BINARY to its path.")
        )
    }

    private static func backendCacheKey(_ backend: BeancountBackend) -> String {
        switch backend {
        case .rledger(let executablePath):
            return "rledger:\(executablePath)"
        case .python(let executablePath):
            return "python:\(executablePath)"
        }
    }

    private static func resolvedBackendVersion(
        _ backend: BeancountBackend,
        connectAttempt: BeancountConnectAttempt?
    ) throws -> String {
        switch backend {
        case .rledger(let executablePath):
            let name = "rledger"
            guard let version = try reportedVersion(
                executablePath: executablePath,
                arguments: ["--version"],
                connectAttempt: connectAttempt
            ) else {
                return name
            }
            return version.lowercased().hasPrefix("\(name) ") ? version : "\(name) \(version)"
        case .python(let executablePath):
            let name = "Python Beancount"
            guard let version = try reportedVersion(
                executablePath: executablePath,
                arguments: ["-c", "from importlib.metadata import version; print(version('beancount'))"],
                connectAttempt: connectAttempt
            ) else {
                return name
            }
            return "\(name) \(version)"
        }
    }

    private static func reportedVersion(
        executablePath: String,
        arguments: [String],
        connectAttempt: BeancountConnectAttempt?
    ) throws -> String? {
        let output: Data
        do {
            output = try runProcess(
                executablePath: executablePath,
                arguments: arguments,
                failureMessage: "Beancount backend version check failed",
                connectAttempt: connectAttempt
            )
        } catch {
            try connectAttempt?.check()
            logger.warning("Beancount backend version unavailable: \(error)")
            return nil
        }
        let version = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return version.isEmpty ? nil : version
    }

    private static func rledgerSupportsNoCache(
        executablePath: String,
        connectAttempt: BeancountConnectAttempt?
    ) throws -> Bool {
        try connectAttempt?.check()
        if let cached = rledgerNoCacheSupport.withLock({ $0[executablePath] }) {
            return cached
        }

        let supports: Bool
        do {
            let output = try BeancountProcessRunner.run(
                executablePath: executablePath,
                arguments: ["query", "--help"],
                environment: [:],
                connectAttempt: connectAttempt
            )
            var helpData = output.standardOutput
            helpData.append(output.standardError)
            let help = String(data: helpData, encoding: .utf8) ?? ""
            supports = output.terminationStatus == 0 && help.contains("--no-cache")
        } catch {
            try connectAttempt?.check()
            supports = false
        }

        try connectAttempt?.check()
        rledgerNoCacheSupport.withLock { $0[executablePath] = supports }
        return supports
    }

    private static func optionalRustledgerExecutablePath() throws -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["TABLEPRO_RUSTLEDGER_BINARY"], !configured.isEmpty {
            if FileManager.default.isExecutableFile(atPath: configured) {
                return configured
            }
            throw BeancountDriverError.beancountBackendUnavailable(
                String(
                    format: String(localized: "TABLEPRO_RUSTLEDGER_BINARY points to a missing or non-executable rledger at %@"),
                    configured
                )
            )
        }

        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let fallbackDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]
        for directory in pathEntries + fallbackDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("rledger").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    internal static func pythonProjectionRows(
        ledgerPath: String,
        executablePath: String,
        allowsLedgerPlugins: Bool,
        connectAttempt: BeancountConnectAttempt?
    ) throws -> [String: [[String: Any]]] {
        let output = try runProcess(
            executablePath: executablePath,
            arguments: ["-c", pythonProjectionScript, ledgerPath],
            failureMessage: String(localized: "Python Beancount projection failed"),
            environment: ["TABLEPRO_BEANCOUNT_RUN_LEDGER_PLUGINS": allowsLedgerPlugins ? "1" : "0"],
            connectAttempt: connectAttempt
        )
        let object = try JSONSerialization.jsonObject(with: output)
        guard let dictionary = object as? [String: Any] else {
            throw BeancountDriverError.queryFailed(String(localized: "Invalid Python Beancount JSON output"))
        }
        var rows: [String: [[String: Any]]] = [:]
        for (key, value) in dictionary {
            rows[key] = value as? [[String: Any]]
        }
        return rows
    }

    private static func pythonBeancountExecutablePath(
        connectAttempt: BeancountConnectAttempt?
    ) throws -> String {
        if let path = try optionalPythonBeancountExecutablePath(connectAttempt: connectAttempt) {
            return path
        }
        throw BeancountDriverError.beancountBackendUnavailable(
            String(localized: "Python Beancount backend requires python3 with the beancount package installed. Set TABLEPRO_BEANCOUNT_PYTHON to the Python executable if needed.")
        )
    }

    private static func optionalPythonBeancountExecutablePath(
        connectAttempt: BeancountConnectAttempt?
    ) throws -> String? {
        try connectAttempt?.check()
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["TABLEPRO_BEANCOUNT_PYTHON"], !configured.isEmpty {
            if FileManager.default.isExecutableFile(atPath: configured),
               try pythonSupportsBeancount(configured, connectAttempt: connectAttempt) {
                return configured
            }
            throw BeancountDriverError.beancountBackendUnavailable(
                String(
                    format: String(localized: "TABLEPRO_BEANCOUNT_PYTHON points to a Python executable that cannot import beancount at %@"),
                    configured
                )
            )
        }

        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let fallbackCandidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        let candidates = pathEntries.map {
            URL(fileURLWithPath: $0).appendingPathComponent("python3").path
        } + fallbackCandidates

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            if try pythonSupportsBeancount(candidate, connectAttempt: connectAttempt) {
                return candidate
            }
        }
        return nil
    }

    private static func pythonSupportsBeancount(
        _ executablePath: String,
        connectAttempt: BeancountConnectAttempt?
    ) throws -> Bool {
        do {
            _ = try runProcess(
                executablePath: executablePath,
                arguments: ["-c", "import beancount"],
                failureMessage: String(localized: "Python cannot import beancount"),
                connectAttempt: connectAttempt
            )
            return true
        } catch {
            try connectAttempt?.check()
            return false
        }
    }
}
