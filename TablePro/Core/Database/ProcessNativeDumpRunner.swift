//
//  ProcessNativeDumpRunner.swift
//  TablePro
//

import Foundation

/// Spawns and supervises the one subprocess a command-line dump tool needs.
final class ProcessNativeDumpRunner: NativeDumpRunner, @unchecked Sendable {
    private let command: NativeDumpCommand
    private let process = Process()
    private let stderrPipe = Pipe()
    private let stateLock = NSLock()
    private var stderrBuffer = Data()
    private var wasCancelled = false
    private var terminationResult: NativeDumpRunResult?
    private var continuation: CheckedContinuation<NativeDumpRunResult, Never>?
    private var redirectedHandle: FileHandle?
    private var credentialsFileURL: URL?

    init(command: NativeDumpCommand) {
        self.command = command
    }

    func start() throws {
        let stderrCap = command.stderrByteCap

        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = command.environment
        process.standardError = stderrPipe
        credentialsFileURL = command.temporaryCredentialsFileURL

        try attachRedirection(for: command)

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            self.stateLock.lock()
            self.stderrBuffer.append(chunk)
            if self.stderrBuffer.count > stderrCap {
                self.stderrBuffer = Data(self.stderrBuffer.suffix(stderrCap))
            }
            self.stateLock.unlock()
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil
            self.releaseRedirection()

            self.stateLock.lock()
            let stderrText = String(data: self.stderrBuffer, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let result = NativeDumpRunResult(
                exitCode: proc.terminationStatus,
                stderr: stderrText,
                wasCancelled: self.wasCancelled
            )
            self.terminationResult = result
            let pending = self.continuation
            self.continuation = nil
            self.stateLock.unlock()

            pending?.resume(returning: result)
        }

        try process.run()
    }

    func cancel() {
        stateLock.lock()
        wasCancelled = true
        stateLock.unlock()
        if process.isRunning {
            process.terminate()
        }
    }

    /// A tool that writes to standard output gets the destination file as its stdout, and a restore
    /// that reads from standard input gets the dump file as its stdin. The one that manages its own
    /// file gets the null device, which is what keeps a chatty tool from filling a pipe nobody
    /// drains and deadlocking on write.
    private func attachRedirection(for command: NativeDumpCommand) throws {
        guard command.delivery == .standardOutput, let fileURL = command.redirectedFileURL else {
            process.standardOutput = FileHandle.nullDevice
            return
        }
        switch command.isRestore {
        case true:
            guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
                throw NativeDumpError.sourceUnreadable
            }
            let handle = try FileHandle(forReadingFrom: fileURL)
            redirectedHandle = handle
            process.standardInput = handle
            process.standardOutput = FileHandle.nullDevice
        case false:
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw NativeDumpError.sourceUnreadable
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            redirectedHandle = handle
            process.standardOutput = handle
        }
    }

    /// Runs however the process ended, including a cancel, so a credentials file never outlives the
    /// process that needed it.
    private func releaseRedirection() {
        try? redirectedHandle?.close()
        redirectedHandle = nil
        if let credentialsFileURL {
            try? FileManager.default.removeItem(at: credentialsFileURL)
        }
        credentialsFileURL = nil
    }

    var result: NativeDumpRunResult {
        get async {
            await withCheckedContinuation { continuation in
                stateLock.lock()
                if let cached = terminationResult {
                    stateLock.unlock()
                    continuation.resume(returning: cached)
                    return
                }
                self.continuation = continuation
                stateLock.unlock()
            }
        }
    }
}
