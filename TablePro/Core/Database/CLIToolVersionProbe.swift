//
//  CLIToolVersionProbe.swift
//  TablePro
//

import Foundation
import os

/// Asks a command line tool what it is, by running it with `--version`.
///
/// Synchronous on purpose: `NativeDumpDescriptor.CommandLineTool`'s resolution hooks are
/// synchronous closures that `NativeDumpService` already runs inside a detached task, so an async
/// probe would have to change every one of them.
enum CLIToolVersionProbe {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CLIToolVersionProbe")

    static let defaultTimeout: TimeInterval = 3

    /// A version banner is one line. Reading past this is a tool doing something other than
    /// answering the question, and the answer is taken from what arrived rather than waited for.
    static let outputCap = 64 * 1_024

    /// Standard output of `<path> --version`, or nil when the tool cannot run, does not answer in
    /// time, or exits non-zero.
    static func versionOutput(of path: String, timeout: TimeInterval = defaultTimeout) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.environment = CLIToolEnvironment.augmented()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            logger.warning(
                "\(path, privacy: .private(mask: .hash)) did not answer --version within \(timeout, privacy: .public)s"
            )
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let output = DescriptorRead.bufferedBytes(from: pipe.fileHandleForReading.fileDescriptor, upTo: outputCap)
        return String(data: output, encoding: .utf8)
    }
}
