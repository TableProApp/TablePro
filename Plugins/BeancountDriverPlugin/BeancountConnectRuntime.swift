//
//  BeancountConnectRuntime.swift
//  BeancountDriverPlugin
//

import Darwin
import Dispatch
import Foundation
import SQLite3

enum BeancountConnectStopReason {
    case cancelled
    case timedOut
}

final class BeancountConnectAttempt: @unchecked Sendable {
    private let expiration: ContinuousClock.Instant
    private let lock = NSLock()
    private var stopReason: BeancountConnectStopReason?
    private var runningProcess: BeancountRunningProcess?

    init(timeoutMilliseconds: Int, now: ContinuousClock.Instant = .now) {
        expiration = now.advanced(by: .milliseconds(timeoutMilliseconds))
    }

    var remainingMilliseconds: Int {
        let now = ContinuousClock.now
        guard now < expiration else { return 0 }
        let components = now.duration(to: expiration).components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return max(1, Int(milliseconds.rounded(.up)))
    }

    func check() throws {
        if ContinuousClock.now >= expiration {
            stop(.timedOut)
        }
        guard let reason = lock.withLock({ stopReason }) else { return }
        throw Self.error(for: reason)
    }

    func launch(_ process: BeancountRunningProcess) throws {
        lock.lock()
        if stopReason == nil, ContinuousClock.now >= expiration {
            stopReason = .timedOut
        }
        guard let reason = stopReason else {
            do {
                try process.process.run()
                runningProcess = process
                lock.unlock()
                return
            } catch {
                lock.unlock()
                throw error
            }
        }
        lock.unlock()
        throw Self.error(for: reason)
    }

    func finish(_ process: BeancountRunningProcess) {
        lock.withLock {
            guard runningProcess === process else { return }
            runningProcess = nil
        }
    }

    func cancel() {
        stop(.cancelled)
    }

    func timeOut() {
        stop(.timedOut)
    }

    func terminalError() -> any Error {
        let reason = lock.withLock { stopReason } ?? .timedOut
        return Self.error(for: reason)
    }

    private func stop(_ reason: BeancountConnectStopReason) {
        let process = lock.withLock { () -> BeancountRunningProcess? in
            if stopReason == nil {
                stopReason = reason
            }
            return runningProcess
        }
        process?.stop()
    }

    private static func error(for reason: BeancountConnectStopReason) -> any Error {
        switch reason {
        case .cancelled:
            return CancellationError()
        case .timedOut:
            return BeancountDriverError.connectionFailed(String(localized: "Connection timed out"))
        }
    }
}

final class BeancountConnectOperation: @unchecked Sendable {
    private typealias ConnectResult = Result<BeancountProjection, any Error>

    private let attempt: BeancountConnectAttempt
    private let work: @Sendable (BeancountConnectAttempt) throws -> BeancountProjection
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BeancountProjection, any Error>?
    private var terminalResult: ConnectResult?
    private var timeoutWorkItem: DispatchWorkItem?

    init(
        timeoutMilliseconds: Int,
        work: @escaping @Sendable (BeancountConnectAttempt) throws -> BeancountProjection
    ) {
        attempt = BeancountConnectAttempt(timeoutMilliseconds: timeoutMilliseconds)
        self.work = work
    }

    func value(on queue: DispatchQueue) async throws -> BeancountProjection {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(continuation: continuation, on: queue)
            }
        } onCancel: {
            cancel()
        }
    }

    private func start(
        continuation: CheckedContinuation<BeancountProjection, any Error>,
        on queue: DispatchQueue
    ) {
        let state = lock.withLock { () -> (ConnectResult?, DispatchWorkItem?) in
            if let terminalResult {
                return (terminalResult, nil)
            }
            self.continuation = continuation
            let timeoutWorkItem = DispatchWorkItem { [self] in timeOut() }
            self.timeoutWorkItem = timeoutWorkItem
            return (nil, timeoutWorkItem)
        }
        if let result = state.0 {
            continuation.resume(with: result)
            return
        }
        guard let timeoutWorkItem = state.1 else { return }
        let remainingMilliseconds = attempt.remainingMilliseconds
        if remainingMilliseconds == 0 {
            timeOut()
        } else {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .milliseconds(remainingMilliseconds),
                execute: timeoutWorkItem
            )
        }
        queue.async { [self] in execute() }
    }

    private func execute() {
        do {
            try attempt.check()
            let projection = try work(attempt)
            do {
                try attempt.check()
            } catch {
                sqlite3_close(projection.handle)
                throw error
            }
            finish(with: .success(projection))
        } catch {
            finish(with: .failure(error))
        }
    }

    private func cancel() {
        attempt.cancel()
        finish(with: .failure(CancellationError()))
    }

    private func timeOut() {
        attempt.timeOut()
        finish(with: .failure(attempt.terminalError()))
    }

    private func finish(with result: ConnectResult) {
        let action = lock.withLock { () -> (
            continuation: CheckedContinuation<BeancountProjection, any Error>?,
            discardedProjection: BeancountProjection?
        ) in
            guard terminalResult == nil else {
                guard case .success(let projection) = result else { return (nil, nil) }
                return (nil, projection)
            }
            terminalResult = result
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            defer { continuation = nil }
            return (continuation, nil)
        }
        if let discardedProjection = action.discardedProjection {
            sqlite3_close(discardedProjection.handle)
        }
        action.continuation?.resume(with: result)
    }
}

struct BeancountProcessOutput {
    let standardOutput: Data
    let standardError: Data
    let terminationStatus: Int32
}

final class BeancountRunningProcess: @unchecked Sendable {
    let process: Process
    let standardOutput = Pipe()
    let standardError = Pipe()

    private let lock = NSLock()
    private var stopped = false

    init(executablePath: String, arguments: [String], environment: [String: String]) {
        process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment, uniquingKeysWith: { _, override in override })
        }
        process.standardOutput = standardOutput
        process.standardError = standardError
    }

    func closeParentWriteHandles() {
        try? standardOutput.fileHandleForWriting.close()
        try? standardError.fileHandleForWriting.close()
    }

    func closeHandles() {
        try? standardOutput.fileHandleForReading.close()
        try? standardError.fileHandleForReading.close()
        closeParentWriteHandles()
    }

    func stop() {
        let shouldStop = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard shouldStop else { return }
        closeHandles()
        guard process.isRunning else { return }
        let processIdentifier = process.processIdentifier
        process.terminate()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(100)) {
            guard self.process.isRunning else { return }
            Darwin.kill(processIdentifier, SIGKILL)
        }
    }
}

enum BeancountProcessRunner {
    static func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        connectAttempt: BeancountConnectAttempt?
    ) throws -> BeancountProcessOutput {
        let runningProcess = BeancountRunningProcess(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment
        )
        defer {
            connectAttempt?.finish(runningProcess)
            runningProcess.closeHandles()
        }

        if let connectAttempt {
            try connectAttempt.launch(runningProcess)
        } else {
            try runningProcess.process.run()
        }
        runningProcess.closeParentWriteHandles()

        let outputCollector = BeancountPipeDataCollector()
        let errorCollector = BeancountPipeDataCollector()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outputCollector.set(runningProcess.standardOutput.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorCollector.set(runningProcess.standardError.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        runningProcess.process.waitUntilExit()
        readers.wait()
        try connectAttempt?.check()
        return BeancountProcessOutput(
            standardOutput: outputCollector.data,
            standardError: errorCollector.data,
            terminationStatus: runningProcess.process.terminationStatus
        )
    }
}

private final class BeancountPipeDataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.withLock { storage }
    }

    func set(_ data: Data) {
        lock.withLock {
            storage = data
        }
    }
}
