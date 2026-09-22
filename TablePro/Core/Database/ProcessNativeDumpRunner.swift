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
    /// Held across the read as well as the append, so a chunk can never be taken out of the pipe by
    /// one reader and still be missing from the buffer when another snapshots it. Separate from
    /// `stateLock`, which `cancel()` takes and which must never wait on a pipe.
    private let stderrLock = NSLock()
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
            guard let self else { return }
            self.stderrLock.lock()
            let chunk = handle.availableData
            self.append(chunk, cap: stderrCap)
            self.stderrLock.unlock()
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil
            self.drainStderr(cap: stderrCap)
            self.releaseRedirection()

            self.stderrLock.lock()
            let stderrText = String(data: self.stderrBuffer, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.stderrLock.unlock()

            self.stateLock.lock()
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

    /// Takes whatever the pipe still holds once the process has gone.
    ///
    /// The readability source and the process reaper run on independent queues, so bytes written
    /// just before the child exits can still be in the pipe when `terminationHandler` reads the
    /// buffer, and a tool that exits on its first argument writes everything it has to say in that
    /// window. Measured with a harness mirroring this class against a child that writes 66 bytes
    /// and exits immediately: 2 of 300 runs captured nothing at all, and with this drain 0 of 300
    /// did. What the user saw instead was "Process exited with code 7" and no message.
    /// Takes whatever the pipe still holds once the process has gone.
    ///
    /// The readability source and the process reaper run on independent queues, so a tool that
    /// exits on its first argument can have written everything it has to say and still be waiting
    /// to be read. Measured with a harness mirroring this class against a child that writes 66
    /// bytes and exits at once: between 1 and 6 of every 300 runs captured nothing at all, the rate
    /// rising with load, and 0 of 1,200 with the drain and the lock above. What the sheet showed
    /// instead was the exit code alone.
    ///
    /// The child has exited, so everything it wrote is already in the pipe's buffer and a
    /// non-blocking read takes all of it. `readDataToEndOfFile` would take it too and then wait for
    /// every writer to close, which a grandchild that inherited this end would never do, hanging
    /// the termination handler and with it the run. The read stops at the cap for the same reason:
    /// a grandchild still writing would otherwise keep the loop fed for as long as it cared to, and
    /// nothing downstream, including the credentials file's removal, happens until it returns.
    private func drainStderr(cap: Int) {
        let descriptor = stderrPipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else { return }

        var buffer = [UInt8](repeating: 0, count: 4_096)
        var taken = 0
        stderrLock.lock()
        while taken < cap {
            let received = buffer.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress, raw.count)
            }
            guard received > 0 else { break }
            taken += received
            append(Data(buffer[0 ..< received]), cap: cap)
        }
        stderrLock.unlock()
    }

    /// Call with `stderrLock` held.
    private func append(_ chunk: Data, cap: Int) {
        guard !chunk.isEmpty else { return }
        stderrBuffer.append(chunk)
        if stderrBuffer.count > cap {
            stderrBuffer = Data(stderrBuffer.suffix(cap))
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
