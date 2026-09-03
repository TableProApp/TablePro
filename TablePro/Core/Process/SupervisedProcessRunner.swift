//
//  SupervisedProcessRunner.swift
//  TablePro
//

import Foundation

struct SubprocessTermination: Sendable, Equatable {
    let exitCode: Int32
    let wasRequested: Bool
}

protocol SupervisedProcessRunner: AnyObject, Sendable {
    func start(binaryPath: String, arguments: [String], environment: [String: String]) throws
    func stop()
    var processIdentifier: Int32? { get }
    var stderrLines: AsyncStream<String> { get }
    var termination: SubprocessTermination { get async }
}

final class ProcessSupervisedRunner: SupervisedProcessRunner, @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stateLock = NSLock()

    /// Held for the whole of a stderr read, from taking the bytes off the pipe to handing the
    /// lines to the stream, and for the whole of `finish`. The readability callback runs on
    /// Foundation's queue and the termination handler on another thread, so without it a chunk
    /// read just before the process exited could still be on its way to the stream when
    /// `finish` drained an already empty pipe and closed the stream under it.
    private let ingestLock = NSLock()

    private var partialLine = ""
    private var wasRequested = false
    private var terminationResult: SubprocessTermination?
    private var terminationContinuations: [CheckedContinuation<SubprocessTermination, Never>] = []

    let stderrLines: AsyncStream<String>
    private let stderrContinuation: AsyncStream<String>.Continuation

    init() {
        var continuation: AsyncStream<String>.Continuation!
        stderrLines = AsyncStream<String>(bufferingPolicy: .bufferingNewest(100)) { continuation = $0 }
        stderrContinuation = continuation
    }

    var processIdentifier: Int32? {
        let pid = process.processIdentifier
        return pid > 0 ? pid : nil
    }

    func start(binaryPath: String, arguments: [String], environment: [String: String]) throws {
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            self.ingestLock.lock()
            defer { self.ingestLock.unlock() }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self.ingestStderr(chunk)
        }

        process.terminationHandler = { [weak self] proc in
            self?.finish(exitCode: proc.terminationStatus)
        }

        try process.run()
    }

    func stop() {
        stateLock.lock()
        wasRequested = true
        stateLock.unlock()
        if process.isRunning {
            process.terminate()
        }
    }

    var termination: SubprocessTermination {
        get async {
            await withCheckedContinuation { continuation in
                stateLock.lock()
                if let cached = terminationResult {
                    stateLock.unlock()
                    continuation.resume(returning: cached)
                    return
                }
                terminationContinuations.append(continuation)
                stateLock.unlock()
            }
        }
    }

    private func ingestStderr(_ chunk: Data) {
        guard let text = String(data: chunk, encoding: .utf8) else { return }
        stateLock.lock()
        partialLine += text
        var lines: [String] = []
        while let newlineIndex = partialLine.firstIndex(of: "\n") {
            lines.append(String(partialLine[..<newlineIndex]))
            partialLine.removeSubrange(...newlineIndex)
        }
        stateLock.unlock()
        for line in lines {
            stderrContinuation.yield(line)
        }
    }

    private func finish(exitCode: Int32) {
        ingestLock.lock()
        defer { ingestLock.unlock() }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        /// The termination handler can run before the pipe delivers its last readability
        /// callback, and clearing the handler above cancels that callback outright. Whatever is
        /// still buffered is drained here, because a dropped final line is how a process that
        /// announced itself ready right before exiting reads as one that never did. A callback
        /// already dispatched waits on the lock and then finds the pipe at end of file, so it
        /// cannot hand the stream a line after it has been closed.
        if let remaining = try? stderrPipe.fileHandleForReading.readToEnd(), !remaining.isEmpty {
            ingestStderr(remaining)
        }

        stateLock.lock()
        guard terminationResult == nil else {
            stateLock.unlock()
            return
        }
        let trailing = partialLine
        partialLine = ""
        let result = SubprocessTermination(exitCode: exitCode, wasRequested: wasRequested)
        terminationResult = result
        let pending = terminationContinuations
        terminationContinuations.removeAll()
        stateLock.unlock()

        if !trailing.isEmpty {
            stderrContinuation.yield(trailing)
        }
        stderrContinuation.finish()
        for continuation in pending {
            continuation.resume(returning: result)
        }
    }
}
