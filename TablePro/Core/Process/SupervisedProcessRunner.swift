//
//  SupervisedProcessRunner.swift
//  TablePro
//

import Foundation

struct SubprocessTermination: Sendable, Equatable {
    let exitCode: Int32
    let wasRequested: Bool
}

protocol SupervisedProcessRunner: AnyObject {
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
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
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
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        /// The termination handler can run before the pipe delivers its last readability
        /// callback, and clearing the handler above cancels that callback outright. Whatever is
        /// still buffered is drained here, because a dropped final line is how a process that
        /// announced itself ready right before exiting reads as one that never did.
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
