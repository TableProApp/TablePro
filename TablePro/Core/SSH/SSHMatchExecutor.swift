//
//  SSHMatchExecutor.swift
//  TablePro
//

import Foundation
import os

enum SSHMatchExecutor {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHMatchExecutor")
    private static let timeoutSeconds: TimeInterval = 5

    /// Mirrors OpenSSH `Match exec` semantics: runs through `/bin/sh -c`,
    /// stdin/stdout/stderr suppressed, exit 0 = matched. The 5 second timeout
    /// bounds runaway commands so a hung script cannot stall the connect path.
    /// Every invocation is logged at `.notice` so users can audit what their
    /// `~/.ssh/config` caused TablePro to execute.
    static func evaluate(command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        logger.notice("Match exec: \(trimmed, privacy: .public)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", trimmed]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logger.warning("Match exec failed to start: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let timeoutWorkItem = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeoutSeconds,
            execute: timeoutWorkItem
        )

        process.waitUntilExit()
        timeoutWorkItem.cancel()

        if process.terminationReason == .uncaughtSignal {
            logger.notice("Match exec terminated (likely timeout)")
            return false
        }
        return process.terminationStatus == 0
    }
}
