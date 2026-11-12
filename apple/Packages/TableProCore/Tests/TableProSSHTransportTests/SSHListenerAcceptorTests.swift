//
//  SSHListenerAcceptorTests.swift
//  TableProSSHTransportTests
//

import Foundation
import os
import TableProSSHTransport
import TableProTestSupport
import Testing

struct SSHListenerAcceptorTests {
    @Test("A client that connects is reported once, with a blocking descriptor")
    func reportsAConnectedClientOnce() async throws {
        let listener = try LoopbackListener()
        defer { listener.close() }
        let clients = AcceptedClients()
        let acceptor = SSHListenerAcceptor(listenFD: listener.descriptor, queue: Self.acceptQueue()) { clients.record($0) }
        acceptor.start()

        let peer = try listener.connect()
        defer { Darwin.close(peer) }

        #expect(await Self.finishes { await clients.arrived(1) })
        acceptor.cancel()
        #expect(await Self.finishes { await acceptor.waitForCancellation() })

        let accepted = clients.descriptors
        defer { accepted.forEach { _ = Darwin.close($0) } }
        #expect(accepted.count == 1)
        #expect(accepted.allSatisfy { Self.isBlocking($0) })
    }

    @Test("Two clients that connect back to back are both reported")
    func reportsBackToBackClients() async throws {
        let listener = try LoopbackListener()
        defer { listener.close() }
        let clients = AcceptedClients()
        let acceptor = SSHListenerAcceptor(listenFD: listener.descriptor, queue: Self.acceptQueue()) { clients.record($0) }
        acceptor.start()

        let first = try listener.connect()
        defer { Darwin.close(first) }
        let second = try listener.connect()
        defer { Darwin.close(second) }

        #expect(await Self.finishes { await clients.arrived(2) })
        acceptor.cancel()
        #expect(await Self.finishes { await acceptor.waitForCancellation() })

        let accepted = clients.descriptors
        defer { accepted.forEach { _ = Darwin.close($0) } }
        #expect(accepted.count == 2)
        #expect(Set(accepted).count == 2)
        #expect(accepted.allSatisfy { Self.isBlocking($0) })
    }

    @Test("After cancel the completion fires, and a client that connects later is left for someone else")
    func cancelStopsAccepting() async throws {
        let listener = try LoopbackListener()
        defer { listener.close() }
        let clients = AcceptedClients()
        let acceptor = SSHListenerAcceptor(listenFD: listener.descriptor, queue: Self.acceptQueue()) { clients.record($0) }
        acceptor.start()

        acceptor.cancel()
        #expect(await Self.finishes { await acceptor.waitForCancellation() })

        let late = try listener.connect()
        defer { Darwin.close(late) }
        // Accepting it here proves the cancelled acceptor did not take it and never can.
        let taken = try listener.acceptWaiting()
        defer { Darwin.close(taken) }
        #expect(clients.descriptors.isEmpty)
    }

    @Test("Cancelling more than once, from several threads, is safe")
    func cancelIsIdempotent() async throws {
        let listener = try LoopbackListener()
        defer { listener.close() }
        let acceptor = SSHListenerAcceptor(listenFD: listener.descriptor, queue: Self.acceptQueue()) { _ = Darwin.close($0.descriptor) }
        acceptor.start()

        DispatchQueue.concurrentPerform(iterations: 8) { _ in acceptor.cancel() }
        acceptor.cancel()

        #expect(await Self.finishes { await acceptor.waitForCancellation() })
        #expect(await Self.finishes { await acceptor.waitForCancellation() })
    }

    @Test("An acceptor cancelled before it started still completes")
    func cancelBeforeStartCompletes() async throws {
        let listener = try LoopbackListener()
        defer { listener.close() }
        let acceptor = SSHListenerAcceptor(listenFD: listener.descriptor, queue: Self.acceptQueue()) { _ = Darwin.close($0.descriptor) }

        acceptor.cancel()

        #expect(await Self.finishes { await acceptor.waitForCancellation() })
    }

    private static func acceptQueue() -> DispatchQueue {
        DispatchQueue(label: "com.TablePro.tests.ssh.accept")
    }

    private static func finishes(_ work: @escaping @Sendable () async -> Void) async -> Bool {
        await BoundedCall.result(of: work) != nil
    }

    private static func isBlocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL, 0)
        return flags >= 0 && flags & O_NONBLOCK == 0
    }
}

private struct SocketFailure: Error, CustomStringConvertible {
    let call: String
    let code: Int32

    var description: String { "\(call) failed: \(String(cString: strerror(code)))" }
}

private struct LoopbackListener {
    let descriptor: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketFailure(call: "socket", code: errno) }

        var address = Self.loopback(port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            let failure = SocketFailure(call: "bind", code: errno)
            Darwin.close(fd)
            throw failure
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            let failure = SocketFailure(call: "getsockname", code: errno)
            Darwin.close(fd)
            throw failure
        }

        descriptor = fd
        port = UInt16(bigEndian: assigned.sin_port)
    }

    func close() {
        Darwin.close(descriptor)
    }

    func connect() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketFailure(call: "socket", code: errno) }

        var address = Self.loopback(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            let failure = SocketFailure(call: "connect", code: errno)
            Darwin.close(fd)
            throw failure
        }
        return fd
    }

    // Returns as soon as a connection is pending; the timeout only bounds a failing run.
    func acceptWaiting() throws -> Int32 {
        var pollFD = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&pollFD, 1, 10_000) == 1 else { throw SocketFailure(call: "poll", code: errno) }
        let fd = accept(descriptor, nil, nil)
        guard fd >= 0 else { throw SocketFailure(call: "accept", code: errno) }
        return fd
    }

    private static func loopback(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }
}

private final class AcceptedClients: Sendable {
    private struct State {
        var clients: [SSHAcceptedClient] = []
        var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var descriptors: [Int32] {
        state.withLock { $0.clients.map { $0.descriptor } }
    }

    func record(_ client: SSHAcceptedClient) {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.clients.append(client)
            let total = state.clients.count
            let due = state.waiters.filter { $0.count <= total }.map { $0.continuation }
            state.waiters.removeAll { $0.count <= total }
            return due
        }
        ready.forEach { $0.resume() }
    }

    func arrived(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isReady = state.withLock { state -> Bool in
                guard state.clients.count < count else { return true }
                state.waiters.append((count, continuation))
                return false
            }
            if isReady { continuation.resume() }
        }
    }
}
