//
//  PrivilegedShell.swift
//  TablePro
//

import Foundation
import os

internal enum PrivilegedShellError: Error, LocalizedError, Equatable {
    case cancelled
    case failed(String)

    internal var errorDescription: String? {
        switch self {
        case .cancelled:
            return String(localized: "Cancelled by user.")
        case .failed(let reason):
            return reason
        }
    }
}

@MainActor
internal protocol PrivilegedShellRunning {
    func run(_ command: String) throws
}

@MainActor
internal struct OSAScriptPrivilegedShell: PrivilegedShellRunning {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PrivilegedShell")

    internal static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    internal static func appleScript(for command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    internal func run(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", Self.appleScript(for: command)]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw PrivilegedShellError.failed(error.localizedDescription)
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return }

        let message = (String(data: errorData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("-128") || message.localizedCaseInsensitiveContains("cancel") {
            throw PrivilegedShellError.cancelled
        }
        Self.logger.error("Privileged command failed: \(message, privacy: .public)")
        throw PrivilegedShellError.failed(message)
    }
}
