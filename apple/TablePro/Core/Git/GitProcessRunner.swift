//
//  GitProcessRunner.swift
//  TablePro
//

import Foundation
import os

internal struct GitProcessResult: Sendable {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data
    // False when a child of git still held the output open after the grace period, so more may have followed.
    var isComplete = true

    var succeeded: Bool { exitCode == 0 }

    var errorMessage: String {
        Self.text(standardError)
    }

    // Some failures, such as "nothing to commit", are reported on standard output.
    var combinedOutput: String {
        [Self.text(standardOutput), errorMessage].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func text(_ data: Data) -> String {
        (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

internal enum GitProcessError: Error, Equatable {
    case launchFailed(String)
    case timedOut
    case outputTooLarge
}

internal struct GitProcessRunner: Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "GitProcessRunner")

    static let defaultTimeout: TimeInterval = 20
    static let defaultOutputLimit = 128 * 1_024 * 1_024
    static let errorOutputLimit = 64 * 1_024
    static let pipeDrainGrace: TimeInterval = 1

    let executableURL: URL
    var timeout: TimeInterval = defaultTimeout
    var outputLimit: Int = defaultOutputLimit

    func run(_ command: GitCommand) async throws -> GitProcessResult {
        let handle = RunningProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try runSynchronously(command, handle: handle) })
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    private func runSynchronously(_ command: GitCommand, handle: RunningProcess) throws -> GitProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = command.processArguments
        process.currentDirectoryURL = command.workingDirectory
        process.environment = command.environment(base: ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        guard !handle.isCancelled else { throw CancellationError() }
        do {
            try process.run()
        } catch {
            throw GitProcessError.launchFailed(error.localizedDescription)
        }
        handle.started(process)

        let output = BoundedBuffer(limit: outputLimit)
        let errors = BoundedBuffer(limit: Self.errorOutputLimit)
        let readers = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: readers) {
            Self.drain(outputPipe.fileHandleForReading, into: output) { handle.terminate() }
        }
        DispatchQueue.global(qos: .utility).async(group: readers) {
            Self.drain(errorPipe.fileHandleForReading, into: errors, onOverflow: nil)
        }

        let limit = command.timeout ?? timeout
        guard exited.wait(timeout: .now() + limit) == .success else {
            handle.terminate()
            _ = readers.wait(timeout: .now() + 2)
            Self.logger.warning("git \(command.arguments.first ?? "", privacy: .public) timed out after \(limit, privacy: .public)s")
            throw GitProcessError.timedOut
        }
        // A hook's background job or an SSH ControlPersist master keeps the pipes open after git exits.
        let drained = readers.wait(timeout: .now() + Self.pipeDrainGrace) == .success
        if !drained {
            Self.logger.debug("git \(command.arguments.first ?? "", privacy: .public) left its output open in a child process")
        }

        // A git that finished before the signal reached it did the work, so its result stands.
        guard !(handle.isCancelled && process.terminationReason == .uncaughtSignal) else { throw CancellationError() }
        guard !output.overflowed else { throw GitProcessError.outputTooLarge }
        return GitProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: output.data,
            standardError: errors.data,
            isComplete: drained
        )
    }

    private static func drain(_ handle: FileHandle, into buffer: BoundedBuffer, onOverflow: (@Sendable () -> Void)?) {
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 64 * 1_024) ?? Data()
            } catch {
                return
            }
            guard !chunk.isEmpty else { return }
            guard buffer.append(chunk) || onOverflow == nil else {
                onOverflow?()
                return
            }
        }
    }
}

private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func started(_ process: Process) {
        let cancelledFirst = lock.withLock {
            self.process = process
            return cancelled
        }
        if cancelledFirst { terminate() }
    }

    func cancel() {
        lock.withLock { cancelled = true }
        terminate()
    }

    func terminate() {
        guard let process = lock.withLock({ process }), process.isRunning else { return }
        process.terminate()
    }
}

private final class BoundedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var didOverflow = false

    init(limit: Int) {
        self.limit = limit
    }

    var data: Data {
        lock.withLock { storage }
    }

    var overflowed: Bool {
        lock.withLock { didOverflow }
    }

    func append(_ chunk: Data) -> Bool {
        lock.withLock {
            guard storage.count + chunk.count <= limit else {
                didOverflow = true
                return false
            }
            storage.append(chunk)
            return true
        }
    }
}
