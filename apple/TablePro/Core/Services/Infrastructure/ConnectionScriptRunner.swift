//
//  ConnectionScriptRunner.swift
//  TablePro
//

import Darwin
import Foundation
import TableProUtilities

enum ConnectionScriptOutcome: Equatable, Sendable {
    case succeeded
    case failed(exitCode: Int32, stderr: String)
    case timedOut
}

enum ConnectionScriptRunner {
    static let defaultTimeoutSeconds = 10
    static let timeoutSecondsRange = 1 ... 300

    private static let forcedStopGrace = Duration.seconds(2)

    static func run(
        _ script: String,
        environment: [String: String],
        timeoutSeconds: Int,
        clock: any Clock<Duration> = ContinuousClock()
    ) async throws -> ConnectionScriptOutcome {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.environment = CLIToolEnvironment.augmented().merging(environment) { _, connection in connection }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        let stderr = ScriptOutput()
        let stderrReader = PipeReader(stderrPipe.fileHandleForReading)
        stderrReader.start { stderr.append($0) }
        let exit = ScriptExit()
        process.terminationHandler = { _ in exit.finish() }
        try process.run()

        let stopper = ScriptStopper(process: process, grace: forcedStopGrace)
        let timeout = Task {
            try await clock.sleep(for: .seconds(timeoutSeconds))
            stopper.stop()
        }
        await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            stopper.stop()
        }
        timeout.cancel()
        // A helper the script left in the background keeps stderr open, so read only what is already there.
        stderrReader.stop(drainingUpTo: DescriptorRead.pipeCapacity)

        try Task.checkCancellation()
        if stopper.wasStopped, process.terminationReason == .uncaughtSignal {
            return .timedOut
        }
        if process.terminationStatus != 0 {
            return .failed(exitCode: process.terminationStatus, stderr: stderr.text)
        }
        return .succeeded
    }
}

enum PreConnectScriptError: LocalizedError, Equatable {
    case failed(exitCode: Int32, stderr: String)
    case timedOut(seconds: Int)

    var errorDescription: String? {
        switch self {
        case let .failed(exitCode, stderr):
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                return String(format: String(localized: "Pre-connect script failed with exit code %d"), exitCode)
            }
            return String(format: String(localized: "Pre-connect script failed (exit %d): %@"), exitCode, message)
        case let .timedOut(seconds):
            return String(format: String(localized: "Pre-connect script timed out after %d seconds"), seconds)
        }
    }
}

private final class ScriptOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    var text: String {
        lock.withLock { String(data: data, encoding: .utf8) ?? "" }
    }
}

private final class ScriptExit: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<Void, Never>?

    func finish() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            finished = true
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let alreadyFinished = lock.withLock { () -> Bool in
                if !finished { continuation = waiter }
                return finished
            }
            if alreadyFinished { waiter.resume() }
        }
    }
}

// Signals the script's whole process group, so whatever it started goes too, and kills what ignores SIGTERM.
private final class ScriptStopper: @unchecked Sendable {
    private let process: Process
    private let grace: Duration
    private let lock = NSLock()
    private var stopped = false

    init(process: Process, grace: Duration) {
        self.process = process
        self.grace = grace
    }

    var wasStopped: Bool {
        lock.withLock { stopped }
    }

    func stop() {
        let first = lock.withLock { () -> Bool in
            defer { stopped = true }
            return !stopped
        }
        guard first, process.isRunning else { return }
        let pid = process.processIdentifier
        if kill(-pid, SIGTERM) != 0 {
            process.terminate()
        }
        Task.detached { [process, grace] in
            try? await Task.sleep(for: grace)
            if process.isRunning {
                kill(-pid, SIGKILL)
            }
        }
    }
}
