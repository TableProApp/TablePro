//
//  SupervisedProcessRunner.swift
//  TablePro
//

import Darwin
import Foundation
import TableProProcess

struct SubprocessTermination: Sendable, Equatable {
    let exitCode: Int32
    let wasRequested: Bool
}

protocol SupervisedProcessRunner: AnyObject, Sendable {
    func start(_ command: ProcessCommand) throws
    func stop()
    var processIdentifier: Int32? { get }
    var stderrLines: AsyncStream<String> { get }
    var termination: SubprocessTermination { get async }
}

final class ProcessSupervisedRunner: SupervisedProcessRunner, @unchecked Sendable {
    private var process: Process?
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutReader: PipeReader
    private let stderrReader: PipeReader
    private let stateLock = NSLock()

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
        stdoutReader = PipeReader(stdoutPipe.fileHandleForReading)
        stderrReader = PipeReader(stderrPipe.fileHandleForReading)
    }

    var processIdentifier: Int32? {
        guard let pid = stateLock.withLock({ process })?.processIdentifier, pid > 0 else { return nil }
        return pid
    }

    func start(_ command: ProcessCommand) throws {
        let process = try ProcessLauncher.process(for: command)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] proc in
            self?.finish(exitCode: proc.terminationStatus)
        }
        stateLock.withLock { self.process = process }

        stdoutReader.start { _ in }
        stderrReader.start { [weak self] chunk in
            self?.ingestStderr(chunk)
        }

        try process.run()
    }

    // The group, not the pid: a helper the command spawned (aws ssm runs session-manager-plugin, which
    // holds the port) inherits it, and SIGKILL follows for one that ignores SIGTERM.
    func stop() {
        stateLock.lock()
        let alreadyRequested = wasRequested
        wasRequested = true
        let process = self.process
        stateLock.unlock()
        guard !alreadyRequested, let process, process.isRunning else { return }

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

    // Both halves: the termination handler runs once Foundation reaped the child, so a forced kill never
    // reaches a group that inherited a recycled pid.
    private var isUnterminated: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return terminationResult == nil && process?.isRunning == true
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
        stdoutReader.stop()
        stderrReader.stopAtEndOfFile()

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
