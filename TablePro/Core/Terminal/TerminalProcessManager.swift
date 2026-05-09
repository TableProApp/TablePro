//
//  TerminalProcessManager.swift
//  TablePro
//

import Darwin
import Foundation
import os

@MainActor
final class TerminalProcessManager {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "TerminalProcessManager")

    private let fdLock = NSLock()
    nonisolated(unsafe) private var _ptyFD: Int32 = -1

    private var ptyFD: Int32 {
        get { fdLock.withLock { _ptyFD } }
        set { fdLock.withLock { _ptyFD = newValue } }
    }

    private let stateLock = NSLock()
    nonisolated(unsafe) private var _childPID: pid_t = 0
    nonisolated(unsafe) private var _readSource: DispatchSourceRead?
    nonisolated(unsafe) private var _processMonitor: DispatchSourceProcess?

    var onData: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    private var isRunning: Bool { _childPID > 0 }

    static let registry = TerminalProcessRegistry()

    // MARK: - Launch

    func launch(spec: CLILaunchSpec) throws {
        guard !isRunning else {
            Self.logger.warning("Process already running, ignoring launch request")
            return
        }

        // Pre-build all C strings BEFORE fork. After fork, the child must only
        // use async-signal-safe POSIX calls (execve, _exit) — no Swift allocations.
        let allArgs = [spec.executablePath] + spec.arguments
        var env = ProcessInfo.processInfo.environment
        for (key, value) in spec.environment {
            env[key] = value
        }
        env["TERM"] = "xterm-256color"

        let cArgs: [UnsafeMutablePointer<CChar>?] = allArgs.map { strdup($0) } + [nil]
        let envStrings = env.map { "\($0.key)=\($0.value)" }
        let cEnv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]

        var ptyFDValue: Int32 = -1
        var winSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)

        let pid = forkpty(&ptyFDValue, nil, nil, &winSize)

        if pid < 0 {
            let forkErrno = errno
            for ptr in cArgs { ptr.map { free($0) } }
            for ptr in cEnv { ptr.map { free($0) } }
            throw TerminalError.forkFailed(errno: forkErrno)
        }

        if pid == 0 {
            // Child process: ONLY async-signal-safe POSIX calls, no Swift
            execve(cArgs[0]!, cArgs, cEnv) // swiftlint:disable:this force_unwrapping
            _exit(127)
        }

        // Parent process: free the strdup'd strings
        for ptr in cArgs { ptr.map { free($0) } }
        for ptr in cEnv { ptr.map { free($0) } }
        self.ptyFD = ptyFDValue
        self._childPID = pid

        let fullCmd = ([spec.executablePath] + spec.arguments).joined(separator: " ")
        Self.logger.info("Launched: \(fullCmd, privacy: .public) pid=\(pid)")

        Self.registry.register(self)
        startReadingOutput()
        monitorChildExit()
    }

    // MARK: - Write (called from libghostty threads)

    nonisolated func write(_ data: Data) {
        guard !data.isEmpty else { return }
        let fd = fdLock.withLock { _ptyFD }
        guard fd >= 0 else { return }
        let total = data.count
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            var remaining = total
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(fd, ptr.advanced(by: offset), remaining)
                if written > 0 {
                    offset += written
                    remaining -= written
                    continue
                }
                if written == 0 {
                    Self.logger.error("PTY write returned 0; aborting after \(offset) of \(total) bytes")
                    return
                }
                let err = errno
                if err == EINTR {
                    continue
                }
                Self.logger.error("PTY write failed errno=\(err) after \(offset) of \(total) bytes")
                return
            }
        }
    }

    // MARK: - Resize (called from libghostty threads)

    nonisolated(unsafe) private var lastCols: Int = 0
    nonisolated(unsafe) private var lastRows: Int = 0
    private let resizeLock = NSLock()

    nonisolated func resize(cols: Int, rows: Int) {
        let shouldResize = resizeLock.withLock {
            guard cols != lastCols || rows != lastRows else { return false }
            lastCols = cols
            lastRows = rows
            return true
        }
        guard shouldResize else { return }

        let fd = fdLock.withLock { _ptyFD }
        guard fd >= 0 else { return }
        var size = winsize(
            ws_row: UInt16(clamping: max(0, rows)),
            ws_col: UInt16(clamping: max(0, cols)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(fd, TIOCSWINSZ, &size)
    }

    // MARK: - Terminate

    func terminate() {
        killAndReap()
        cancelSources()

        if ptyFD >= 0 {
            close(ptyFD)
            ptyFD = -1
        }

        Self.registry.unregister(self)
    }

    nonisolated func terminateSync() {
        killAndReap()
        cancelSources()

        let fd = fdLock.withLock { _ptyFD }
        if fd >= 0 {
            Darwin.close(fd)
            fdLock.withLock { _ptyFD = -1 }
        }
    }

    nonisolated private func killAndReap() {
        let pid = stateLock.withLock {
            let p = _childPID
            _childPID = 0
            return p
        }
        guard pid > 0 else { return }
        kill(pid, SIGHUP)
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == 0 {
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
    }

    nonisolated private func cancelSources() {
        stateLock.withLock {
            _readSource?.cancel()
            _readSource = nil
            _processMonitor?.cancel()
            _processMonitor = nil
        }
    }

    deinit {
        stateLock.withLock {
            _readSource?.cancel()
            _processMonitor?.cancel()
        }
        let fd = fdLock.withLock { _ptyFD }
        if fd >= 0 { Darwin.close(fd) }
        let pid = stateLock.withLock { _childPID }
        if pid > 0 { kill(pid, SIGKILL) }
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
        stateLock.withLock { _readSource = source }
    }

    private func monitorChildExit() {
        let pid = stateLock.withLock { _childPID }
        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            // Process source guarantees exit — blocking waitpid returns immediately
            let ret = waitpid(pid, &status, 0)
            guard ret == pid else { return }
            let exitCode: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -1
            Task { @MainActor [weak self] in
                self?.handleProcessExit(exitCode: exitCode)
            }
        }

        source.resume()
        stateLock.withLock { _processMonitor = source }
    }

    private func handleProcessExit(exitCode: Int32) {
        let wasRunning = stateLock.withLock {
            guard _childPID > 0 else { return false }
            _childPID = 0
            return true
        }
        guard wasRunning else { return }
        Self.logger.info("Child process exited status=\(exitCode)")
        Self.registry.unregister(self)
        onExit?(exitCode)
    }
}

// MARK: - Registry

final class TerminalProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var managers: [ObjectIdentifier: TerminalProcessManager] = [:]

    func register(_ manager: TerminalProcessManager) {
        lock.withLock { managers[ObjectIdentifier(manager)] = manager }
    }

    func unregister(_ manager: TerminalProcessManager) {
        lock.withLock { managers.removeValue(forKey: ObjectIdentifier(manager)) }
    }

    func terminateAllSync() {
        let snapshot = lock.withLock { Array(managers.values) }
        for manager in snapshot {
            manager.terminateSync()
        }
        lock.withLock { managers.removeAll() }
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
