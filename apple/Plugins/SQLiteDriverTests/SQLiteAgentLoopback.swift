//
//  SQLiteAgentLoopback.swift
//  SQLiteDriverTests
//

import Darwin
import Foundation
import os

// The SSH session's stand-in: a loopback listener that admits one client by its token line, runs the agent under
// the local python3, and relays each direction on its own thread, so the agent's output can wait on a reader that
// stopped while the client's frames keep reaching it, as over the session pump. When the agent exits, the client's
// socket closes, as the relay's does when its channel closes.
final class SQLiteAgentLoopback: @unchecked Sendable {
    static var python3Path: String? {
        ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    // How the launcher runs the shipped program.
    static var shippedArguments: [String] {
        ["-I", "-S", "-c", RemoteSQLiteAgentSource.interpreterBootstrap, RemoteSQLiteAgentSource.encodedProgram]
    }

    let port: Int
    let token = UUID().uuidString

    private struct Counters {
        var agentBytes = 0
        var heartbeats = 0
        var requests = 0
        var clientClosed = false
    }

    private let listenFD: Int32
    private let executable: String
    private let arguments: [String]
    private let showsErrors: Bool
    private let counters = OSAllocatedUnfairLock(initialState: Counters())
    private let process = OSAllocatedUnfairLock<Process?>(initialState: nil)

    // The local python3 by default; a probe passes ssh and the launcher command to run the agent on a real server,
    // and keeps ssh's own errors on standard error.
    init(
        arguments: [String] = SQLiteAgentLoopback.shippedArguments,
        executable: String? = nil,
        showsErrors: Bool = false
    ) throws {
        guard let executable = executable ?? Self.python3Path else { throw LoopbackError.noPython }
        self.executable = executable
        self.arguments = arguments
        self.showsErrors = showsErrors

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LoopbackError.socket }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, named == 0, listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw LoopbackError.socket
        }
        listenFD = fd
        port = Int(UInt16(bigEndian: address.sin_port))

        Thread.detachNewThread { [self] in acceptOne() }
    }

    // Bytes the agent wrote toward the client.
    var agentBytes: Int { counters.withLock { $0.agentBytes } }
    var heartbeats: Int { counters.withLock { $0.heartbeats } }
    // Execute frames the client sent.
    var requests: Int { counters.withLock { $0.requests } }
    var agentIsRunning: Bool { process.withLock { $0?.isRunning ?? false } }
    var clientClosed: Bool { counters.withLock { $0.clientClosed } }

    func killAgent() {
        process.withLock { $0?.terminate() }
    }

    func close() {
        killAgent()
        shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
    }

    enum LoopbackError: Error { case noPython, socket }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        guard readLine(client) == "TPRSQL1 \(token)" else {
            Darwin.close(client)
            return
        }

        let toAgent = Pipe()
        let fromAgent = Pipe()
        let agent = Process()
        agent.executableURL = URL(fileURLWithPath: executable)
        agent.arguments = arguments
        agent.standardInput = toAgent
        agent.standardOutput = fromAgent
        agent.standardError = showsErrors ? FileHandle.standardError : FileHandle.nullDevice
        do {
            try agent.run()
        } catch {
            Darwin.close(client)
            return
        }
        process.withLock { $0 = agent }
        let agentInput = toAgent.fileHandleForWriting.fileDescriptor
        _ = fcntl(agentInput, F_SETNOSIGPIPE, 1)
        let agentOutput = fromAgent.fileHandleForReading.fileDescriptor

        Thread.detachNewThread { [self] in
            relayToAgent(from: client, to: agentInput)
            toAgent.fileHandleForWriting.closeFile()
            Darwin.close(client)
            counters.withLock { $0.clientClosed = true }
        }
        Thread.detachNewThread { [self] in
            relayToClient(from: agentOutput, to: client)
            shutdown(client, SHUT_RDWR)
        }
    }

    private func readLine(_ fd: Int32) -> String? {
        var line = Data()
        var byte: UInt8 = 0
        while line.count < 256 {
            guard recv(fd, &byte, 1, 0) == 1 else { return nil }
            if byte == 0x0A { return String(data: line, encoding: .utf8) }
            line.append(byte)
        }
        return nil
    }

    // Counts each frame by its opcode on the way: 0x04 is a heartbeat, 0x02 and 0x06 an execute.
    private func relayToAgent(from client: Int32, to agentInput: Int32) {
        var buffer = [UInt8](repeating: 0, count: 32_768)
        var frames: [UInt8] = []
        while true {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            frames.append(contentsOf: buffer[0..<count])
            var offset = 0
            while frames.count - offset >= 5 {
                let length = frames[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
                guard frames.count - offset >= 4 + length else { break }
                let opcode = frames[offset + 4]
                counters.withLock {
                    if opcode == 0x04 { $0.heartbeats += 1 }
                    if opcode == 0x02 || opcode == 0x06 { $0.requests += 1 }
                }
                offset += 4 + length
            }
            frames.removeFirst(offset)
            guard writeAll(buffer[0..<count], to: agentInput) else { return }
        }
    }

    private func relayToClient(from agentOutput: Int32, to client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 32_768)
        while true {
            let count = read(agentOutput, &buffer, buffer.count)
            guard count > 0 else { return }
            counters.withLock { $0.agentBytes += count }
            guard writeAll(buffer[0..<count], to: client) else { return }
        }
    }

    private func writeAll(_ bytes: ArraySlice<UInt8>, to fd: Int32) -> Bool {
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
