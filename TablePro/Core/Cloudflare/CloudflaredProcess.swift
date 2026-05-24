//
//  CloudflaredProcess.swift
//  TablePro
//
//  Spawns and supervises a single long-lived `cloudflared access tcp` process.
//  The Process work is fronted by a protocol so CloudflareTunnelManager can be
//  tested with a fake runner.
//

import Foundation

/// Terminal state of a cloudflared process.
struct CloudflaredTermination: Sendable, Equatable {
    let exitCode: Int32
    let wasRequested: Bool
}

/// Launches and supervises one cloudflared subprocess. Abstracted so the tunnel
/// manager can be exercised in tests without spawning a real process.
protocol CloudflaredRunner: AnyObject {
    /// Launches cloudflared. Throws synchronously if the binary can't be spawned.
    func start(binaryPath: String, arguments: [String], environment: [String: String]) throws
    /// Sends SIGTERM. Safe to call multiple times and from any thread.
    func stop()
    /// PID of the running child, or nil before launch / after exit.
    var processIdentifier: Int32? { get }
    /// Stderr emitted by cloudflared, split into lines. Finishes when the process exits.
    var stderrLines: AsyncStream<String> { get }
    /// Resolves once the process has terminated (normally or via stop()).
    var termination: CloudflaredTermination { get async }
}

// MARK: - Process-backed runner

final class ProcessCloudflaredRunner: CloudflaredRunner {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stateLock = NSLock()

    private var partialLine = ""
    private var wasRequested = false
    private var terminationResult: CloudflaredTermination?
    private var terminationContinuation: CheckedContinuation<CloudflaredTermination, Never>?

    let stderrLines: AsyncStream<String>
    private let stderrContinuation: AsyncStream<String>.Continuation

    init() {
        var continuation: AsyncStream<String>.Continuation!
        // Bound the buffer: once the tunnel is ready nobody drains this stream,
        // but cloudflared keeps logging for the life of the connection.
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

    var termination: CloudflaredTermination {
        get async {
            await withCheckedContinuation { continuation in
                stateLock.lock()
                if let cached = terminationResult {
                    stateLock.unlock()
                    continuation.resume(returning: cached)
                    return
                }
                terminationContinuation = continuation
                stateLock.unlock()
            }
        }
    }

    // MARK: - Private

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

        stateLock.lock()
        let trailing = partialLine
        partialLine = ""
        let result = CloudflaredTermination(exitCode: exitCode, wasRequested: wasRequested)
        terminationResult = result
        let pending = terminationContinuation
        terminationContinuation = nil
        stateLock.unlock()

        if !trailing.isEmpty {
            stderrContinuation.yield(trailing)
        }
        stderrContinuation.finish()
        pending?.resume(returning: result)
    }
}
