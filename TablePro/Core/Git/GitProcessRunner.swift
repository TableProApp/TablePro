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

    var succeeded: Bool { exitCode == 0 }

    var errorMessage: String {
        (String(bytes: standardError, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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

    let executableURL: URL
    var timeout: TimeInterval = defaultTimeout
    var outputLimit: Int = defaultOutputLimit

    func run(_ command: GitCommand) async throws -> GitProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try runSynchronously(command) })
            }
        }
    }

    private func runSynchronously(_ command: GitCommand) throws -> GitProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = command.processArguments
        process.currentDirectoryURL = command.workingDirectory
        process.environment = GitCommand.environment(base: ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw GitProcessError.launchFailed(error.localizedDescription)
        }

        let handle = RunningProcess(process)
        let output = BoundedBuffer(limit: outputLimit)
        let errors = BoundedBuffer(limit: Self.errorOutputLimit)
        let readers = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: readers) {
            Self.drain(outputPipe.fileHandleForReading, into: output) { handle.terminate() }
        }
        DispatchQueue.global(qos: .utility).async(group: readers) {
            Self.drain(errorPipe.fileHandleForReading, into: errors, onOverflow: nil)
        }

        guard readers.wait(timeout: .now() + timeout) == .success else {
            handle.terminate()
            _ = readers.wait(timeout: .now() + 2)
            Self.logger.warning("git \(command.arguments.first ?? "", privacy: .public) timed out after \(timeout, privacy: .public)s")
            throw GitProcessError.timedOut
        }
        process.waitUntilExit()

        guard !output.overflowed else { throw GitProcessError.outputTooLarge }
        return GitProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: output.data,
            standardError: errors.data
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
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        guard process.isRunning else { return }
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
