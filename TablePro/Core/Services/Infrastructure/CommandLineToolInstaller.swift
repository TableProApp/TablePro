//
//  CommandLineToolInstaller.swift
//  TablePro
//

import Foundation
import os

internal enum CommandLineToolStatus: Equatable, Sendable {
    case notInstalled
    case installed
    case conflict
}

internal enum CommandLineToolError: Error, LocalizedError, Equatable {
    case directoryNotWritable(String)
    case conflict(String)
    case writeFailed(String)

    internal var errorDescription: String? {
        switch self {
        case .directoryNotWritable(let path):
            return String(format: String(localized: "%@ is not writable."), path)
        case .conflict(let path):
            return String(format: String(localized: "A different file already exists at %@."), path)
        case .writeFailed(let reason):
            return reason
        }
    }
}

@MainActor
internal protocol CommandLineToolInstalling {
    var toolPath: String { get }
    var status: CommandLineToolStatus { get }
    var manualInstallCommand: String { get }
    var manualUninstallCommand: String { get }
    func install() throws
    func uninstall() throws
}

@MainActor
internal final class CommandLineToolInstaller: CommandLineToolInstalling {
    internal static let shared = CommandLineToolInstaller()

    private static let logger = Logger(subsystem: "com.TablePro", category: "CommandLineToolInstaller")
    private static let toolName = "tablepro"
    private static let marker = "# TablePro command line tool"
    private static let scriptContents = """
        #!/bin/sh
        \(marker)
        exec open -b com.TablePro "$@"

        """

    private let directory: String
    private let fileManager: FileManager

    internal init(directory: String = "/usr/local/bin", fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    internal var toolPath: String {
        (directory as NSString).appendingPathComponent(Self.toolName)
    }

    internal var status: CommandLineToolStatus {
        guard fileManager.fileExists(atPath: toolPath) else { return .notInstalled }
        guard let contents = try? String(contentsOfFile: toolPath, encoding: .utf8),
              contents.contains(Self.marker)
        else { return .conflict }
        return .installed
    }

    internal var manualInstallCommand: String {
        let escaped = Self.scriptContents.replacingOccurrences(of: "\n", with: "\\n")
        return "sudo mkdir -p \"\(directory)\" && printf '\(escaped)' | sudo tee \"\(toolPath)\" > /dev/null"
            + " && sudo chmod 755 \"\(toolPath)\""
    }

    internal var manualUninstallCommand: String {
        "sudo rm \"\(toolPath)\""
    }

    internal func install() throws {
        guard status != .conflict else { throw CommandLineToolError.conflict(toolPath) }
        guard fileManager.fileExists(atPath: directory), fileManager.isWritableFile(atPath: directory) else {
            throw CommandLineToolError.directoryNotWritable(directory)
        }

        do {
            try Self.scriptContents.write(toFile: toolPath, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolPath)
        } catch {
            Self.logger.error("Failed to install command line tool: \(error.localizedDescription, privacy: .public)")
            throw CommandLineToolError.writeFailed(error.localizedDescription)
        }
        Self.logger.info("Installed command line tool at \(self.toolPath, privacy: .public)")
    }

    internal func uninstall() throws {
        switch status {
        case .notInstalled:
            return
        case .conflict:
            throw CommandLineToolError.conflict(toolPath)
        case .installed:
            do {
                try fileManager.removeItem(atPath: toolPath)
            } catch {
                throw CommandLineToolError.writeFailed(error.localizedDescription)
            }
            Self.logger.info("Removed command line tool at \(self.toolPath, privacy: .public)")
        }
    }
}
