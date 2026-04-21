//
//  TerminalProcessManager.swift
//  TablePro
//

import Darwin
import Foundation
import os

@MainActor
final class TerminalProcessManager {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TerminalProcessManager")

    /// File descriptor for the PTY. Set once during launch, read from any thread
    /// (POSIX fd operations are thread-safe). Stored separately for nonisolated access.
    private let fdLock = NSLock()
    private nonisolated(unsafe) var _ptyFD: Int32 = -1

    private var ptyFD: Int32 {
        get { fdLock.withLock { _ptyFD } }
        set { fdLock.withLock { _ptyFD = newValue } }
    }

    private var childPID: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var processMonitor: DispatchSourceProcess?

    var onData: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    private var isRunning: Bool { childPID > 0 }

    // MARK: - Launch

    func launch(spec: CLILaunchSpec) throws {
        guard !isRunning else {
            Self.logger.warning("Process already running, ignoring launch request")
            return
        }

        var ptyFDValue: Int32 = -1
        var winSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)

        let pid = forkpty(&ptyFDValue, nil, nil, &winSize)

        if pid < 0 {
            throw TerminalError.forkFailed(errno: errno)
        }

        if pid == 0 {
            // Child process
            var env = ProcessInfo.processInfo.environment
            for (key, value) in spec.environment {
                env[key] = value
            }

            env["TERM"] = "xterm-256color"

            let envArray = env.map { "\($0.key)=\($0.value)" }
            let cArgs = ([spec.executablePath] + spec.arguments).map { strdup($0) } + [nil]
            let cEnv = envArray.map { strdup($0) } + [nil]

            execve(spec.executablePath, cArgs, cEnv)
            _exit(127)
        }

        // Parent process
        self.ptyFD = ptyFDValue
        self.childPID = pid

        Self.logger.info("Launched \(spec.executablePath, privacy: .public) pid=\(pid)")

        startReadingOutput()
        monitorChildExit()
    }

    // MARK: - Write (called from libghostty threads)

    nonisolated func write(_ data: Data) {
        guard !data.isEmpty else { return }
        let fd = fdLock.withLock { _ptyFD }
        guard fd >= 0 else { return }
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            var remaining = data.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(fd, ptr.advanced(by: offset), remaining)
                if written <= 0 { break }
                offset += written
                remaining -= written
            }
        }
    }

    // MARK: - Resize (called from libghostty threads)

    nonisolated func resize(cols: Int, rows: Int) {
        let fd = fdLock.withLock { _ptyFD }
        guard fd >= 0 else { return }
        var size = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(fd, TIOCSWINSZ, &size)
    }

    // MARK: - Terminate

    func terminate() {
        readSource?.cancel()
        readSource = nil
        processMonitor?.cancel()
        processMonitor = nil

        if childPID > 0 {
            kill(childPID, SIGHUP)
            var status: Int32 = 0
            waitpid(childPID, &status, WNOHANG)
            Self.logger.info("Terminated child pid=\(self.childPID)")
            childPID = 0
        }

        if ptyFD >= 0 {
            close(ptyFD)
            ptyFD = -1
        }
    }

    deinit {
        let fd = fdLock.withLock { _ptyFD }
        if fd >= 0 { close(fd) }
    }

    // MARK: - Private

    private func startReadingOutput() {
        let fd = ptyFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))

        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8_192)
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                Task { @MainActor [weak self] in
                    self?.onData?(data)
                }
            } else {
                source.cancel()
            }
        }

        source.resume()
        self.readSource = source
    }

    private func monitorChildExit() {
        let pid = childPID
        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            let exitStatus = status
            Task { @MainActor [weak self] in
                self?.handleProcessExit(status: exitStatus)
            }
        }

        source.resume()
        self.processMonitor = source
    }

    private func handleProcessExit(status: Int32 = 0) {
        guard childPID > 0 else { return }
        let exitCode = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -1
        Self.logger.info("Child process exited status=\(exitCode)")
        childPID = 0
        onExit?(exitCode)
    }
}

// MARK: - Error

enum TerminalError: LocalizedError {
    case forkFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .forkFailed(let code):
            return String(format: String(localized: "Failed to create terminal process (errno: %d)"), code)
        }
    }
}
