//
//  ProcessNativeDumpRunner.swift
//  TablePro
//

import Foundation
import TableProProcess

final class ProcessNativeDumpRunner: NativeDumpRunner, @unchecked Sendable {
    private let command: NativeDumpCommand
    private let stderrPipe: Pipe
    private let stderrReader: PipeReader
    private let stateLock = NSLock()
    private var process: Process?
    private var stderrBuffer = Data()
    private var wasCancelled = false
    private var terminationResult: NativeDumpRunResult?
    private var continuation: CheckedContinuation<NativeDumpRunResult, Never>?
    private var redirectedHandle: FileHandle?
    private var credentialsFileURL: URL?
    private var pluginFolderURL: URL?

    init(command: NativeDumpCommand, stderrPipe: Pipe = Pipe()) {
        self.command = command
        self.stderrPipe = stderrPipe
        stderrReader = PipeReader(stderrPipe.fileHandleForReading)
    }

    func start() throws {
        let stderrCap = command.stderrByteCap
        credentialsFileURL = command.temporaryCredentialsFileURL
        pluginFolderURL = command.clientPluginFolder?.url

        // A restore cancelled before it launched must not write a single statement.
        guard !stateLock.withLock({ wasCancelled }) else {
            releaseRedirection()
            finish(NativeDumpRunResult(exitCode: SIGTERM, stderr: "", wasCancelled: true, targetUntouched: true))
            return
        }

        let process: Process
        do {
            process = try Self.launchableProcess(for: command)
            try attachRedirection(to: process, for: command)
        } catch {
            releaseRedirection()
            throw error
        }
        process.standardError = stderrPipe

        stderrReader.start { [weak self] chunk in
            self?.append(chunk, cap: stderrCap)
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.stderrReader.stop(drainingUpTo: stderrCap)
            self.releaseRedirection()

            self.stateLock.lock()
            let stderrText = String(data: self.stderrBuffer, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let wasCancelled = self.wasCancelled
            self.stateLock.unlock()

            self.finish(NativeDumpRunResult(exitCode: proc.terminationStatus, stderr: stderrText, wasCancelled: wasCancelled))
        }

        do {
            try process.run()
        } catch {
            stderrReader.stop()
            releaseRedirection()
            throw error
        }

        let cancelledWhileLaunching = stateLock.withLock {
            self.process = process
            return wasCancelled
        }
        if cancelledWhileLaunching, process.isRunning {
            process.terminate()
        }
    }

    // The child reads the dump through a dup of this descriptor, so they share one file offset.
    var bytesRead: Int64? {
        stateLock.withLock {
            guard command.isRestore, let handle = redirectedHandle else { return nil }
            let offset = lseek(handle.fileDescriptor, 0, SEEK_CUR)
            return offset < 0 ? nil : Int64(offset)
        }
    }

    func cancel() {
        let running = stateLock.withLock {
            wasCancelled = true
            return process
        }
        if let running, running.isRunning {
            running.terminate()
        }
    }

    private static func launchableProcess(for command: NativeDumpCommand) throws -> Process {
        do {
            return try ProcessLauncher.process(
                for: ProcessCommand(
                    executable: command.executable,
                    arguments: command.arguments,
                    environment: command.environment
                )
            )
        } catch ProcessLaunchError.nulCharacter {
            throw NativeDumpError.nulInArgument
        }
    }

    private func finish(_ result: NativeDumpRunResult) {
        let pending = stateLock.withLock {
            terminationResult = result
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(returning: result)
    }

    private func append(_ chunk: Data, cap: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        stderrBuffer.append(chunk)
        if stderrBuffer.count > cap {
            stderrBuffer = Data(stderrBuffer.suffix(cap))
        }
    }

    // A tool that writes its own file gets the null device as stdout, so a chatty one never fills a pipe nobody drains.
    private func attachRedirection(to process: Process, for command: NativeDumpCommand) throws {
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
            stateLock.withLock { redirectedHandle = handle }
            process.standardInput = handle
            process.standardOutput = FileHandle.nullDevice
        case false:
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw NativeDumpError.sourceUnreadable
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            stateLock.withLock { redirectedHandle = handle }
            process.standardOutput = handle
        }
    }

    // Runs however the process ended, so a credentials file never outlives the process that needed it.
    // The handle leaves under the lock first, so `bytesRead` never seeks a closed descriptor.
    private func releaseRedirection() {
        let handle = stateLock.withLock {
            let handle = redirectedHandle
            redirectedHandle = nil
            return handle
        }
        try? handle?.close()
        for url in [credentialsFileURL, pluginFolderURL].compactMap(\.self) {
            try? FileManager.default.removeItem(at: url)
        }
        credentialsFileURL = nil
        pluginFolderURL = nil
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
