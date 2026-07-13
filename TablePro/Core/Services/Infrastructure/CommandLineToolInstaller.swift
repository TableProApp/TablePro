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
    case conflict(String)
    case cancelled
    case writeFailed(String)

    internal var errorDescription: String? {
        switch self {
        case .conflict(let path):
            return String(format: String(localized: "A different file already exists at %@."), path)
        case .cancelled:
            return String(localized: "Cancelled by user.")
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
    private let privilegedShell: PrivilegedShellRunning

    internal init(
        directory: String = "/usr/local/bin",
        fileManager: FileManager = .default,
        privilegedShell: PrivilegedShellRunning? = nil
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.privilegedShell = privilegedShell ?? OSAScriptPrivilegedShell()
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

    internal var installCommand: String {
        let script = Self.scriptContents.replacingOccurrences(of: "\n", with: "\\n")
        let quotedDirectory = OSAScriptPrivilegedShell.quote(directory)
        let quotedPath = OSAScriptPrivilegedShell.quote(toolPath)
        return "mkdir -p \(quotedDirectory)"
            + " && printf \(OSAScriptPrivilegedShell.quote(script)) > \(quotedPath)"
            + " && chmod 755 \(quotedPath)"
    }

    internal var uninstallCommand: String {
        "rm -f \(OSAScriptPrivilegedShell.quote(toolPath))"
    }

    internal var manualInstallCommand: String {
        "sudo sh -c \(OSAScriptPrivilegedShell.quote(installCommand))"
    }

    internal var manualUninstallCommand: String {
        "sudo sh -c \(OSAScriptPrivilegedShell.quote(uninstallCommand))"
    }

    internal func install() throws {
        guard status != .conflict else { throw CommandLineToolError.conflict(toolPath) }

        if canWriteDirectly, writeShimDirectly() {
            Self.logger.info("Installed command line tool at \(self.toolPath, privacy: .public)")
            return
        }

        try runPrivileged(installCommand)
        guard status == .installed else {
            throw CommandLineToolError.writeFailed(
                String(format: String(localized: "Could not write %@."), toolPath)
            )
        }
        Self.logger.info("Installed command line tool with administrator rights")
    }

    internal func uninstall() throws {
        switch status {
        case .notInstalled:
            return
        case .conflict:
            throw CommandLineToolError.conflict(toolPath)
        case .installed:
            if (try? fileManager.removeItem(atPath: toolPath)) != nil {
                Self.logger.info("Removed command line tool at \(self.toolPath, privacy: .public)")
                return
            }
            try runPrivileged(uninstallCommand)
            guard status == .notInstalled else {
                throw CommandLineToolError.writeFailed(
                    String(format: String(localized: "Could not remove %@."), toolPath)
                )
            }
        }
    }

    private var canWriteDirectly: Bool {
        fileManager.fileExists(atPath: directory) && fileManager.isWritableFile(atPath: directory)
    }

    private func writeShimDirectly() -> Bool {
        do {
            try Self.scriptContents.write(toFile: toolPath, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolPath)
            return true
        } catch {
            Self.logger.debug("Direct write failed, escalating: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func runPrivileged(_ command: String) throws {
        do {
            try privilegedShell.run(command)
        } catch PrivilegedShellError.cancelled {
            throw CommandLineToolError.cancelled
        } catch {
            throw CommandLineToolError.writeFailed(error.localizedDescription)
        }
    }
}
