import Foundation
import os
import TableProLogRedaction
import TableProProcess

enum SSHMatchExecutor {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHMatchExecutor")
    static let timeoutSeconds: TimeInterval = 5

    private static let killGraceSeconds: TimeInterval = 2

    // `/bin/sh -c` with exit 0 as a match, as in OpenSSH. SIGTERM alone left `trap '' TERM; sleep 300`
    // blocking the connect path (measured), so a command that outlives its grace period gets SIGKILL.
    static func evaluate(command: String) -> Bool {
        evaluate(command: command, timeout: timeoutSeconds)
    }

    static func evaluate(command: String, timeout: TimeInterval) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        logger.notice("Match exec: \(trimmed, privacy: .private)")

        let process: Process
        do {
            // ssh runs it in the user's environment. A value the launcher refuses never ran, so it did not match.
            process = try ProcessLauncher.process(
                for: .userShell(trimmed, shell: .sh, environment: ProcessEnvironment.inherited())
            )
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        } catch {
            logger.warning("Match exec failed to start: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            return false
        }

        let identifier = process.processIdentifier
        let killWorkItem = DispatchWorkItem {
            if process.isRunning {
                kill(identifier, SIGKILL)
            }
        }
        let timeoutWorkItem = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + killGraceSeconds,
                execute: killWorkItem
            )
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutWorkItem
        )

        process.waitUntilExit()
        timeoutWorkItem.cancel()
        killWorkItem.cancel()

        if process.terminationReason == .uncaughtSignal {
            logger.notice("Match exec terminated (likely timeout)")
            return false
        }
        return process.terminationStatus == 0
    }
}
