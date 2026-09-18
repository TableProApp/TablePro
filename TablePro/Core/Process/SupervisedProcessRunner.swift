//
//  SupervisedProcessRunner.swift
//  TablePro
//

import Darwin
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

    private static let forcedTerminationGrace = Duration.seconds(2)

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

    /// Signals the whole process group rather than the child alone, then forces what is left.
    ///
    /// Foundation gives every child its own process group and descendants inherit it, so the group
    /// is the only handle that reaches a helper the command spawned for itself. `aws ssm
    /// start-session` runs `session-manager-plugin` that way, and the plugin is what actually holds
    /// the forwarded port, so signalling the pid alone leaves the port held by an orphan. A
    /// command that then ignores `SIGTERM` would hold it for the life of the app, which is what the
    /// escalation is for.
    func stop() {
        stateLock.lock()
        let alreadyRequested = wasRequested
        wasRequested = true
        stateLock.unlock()
        guard !alreadyRequested, process.isRunning else { return }

        let pid = process.processIdentifier
        guard pid > 1 else {
            process.terminate()
            return
        }
        if kill(-pid, SIGTERM) != 0 {
            process.terminate()
        }
        scheduleForcedTermination(pid: pid)
    }

    private func scheduleForcedTermination(pid: pid_t) {
        Task.detached { [weak self] in
            try? await Task.sleep(for: Self.forcedTerminationGrace)
            guard let self, self.isUnterminated else { return }
            kill(-pid, SIGKILL)
        }
    }

    /// Both halves matter. `terminationResult` is written by the termination handler, which
    /// Foundation runs after it has reaped the child, and `isRunning` goes false at the same
    /// point; checking them together is what keeps a forced kill from ever reaching a process
    /// group that inherited a recycled pid.
    private var isUnterminated: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return terminationResult == nil && process.isRunning
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
