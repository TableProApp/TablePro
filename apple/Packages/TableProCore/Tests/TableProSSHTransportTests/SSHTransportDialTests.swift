//
//  SSHTransportDialTests.swift
//  TableProSSHTransportTests
//

import Foundation
import Testing

@testable import TableProSSHTransport

struct SSHTransportDialTests {
    @Test("A black-holed first address hands over to the live one after one attempt delay, not at the deadline")
    func blackHoledFirstAddressConnectsSecond() throws {
        let blackHole = BlackHole()
        let live = try #require(LoopbackListener())
        let started = ContinuousClock.now

        let outcome = SSHTransportDial.connect(
            [blackHole.address, live.address],
            deadline: started.advanced(by: .seconds(10)),
            interrupt: SSHDialInterrupt(),
            start: blackHole.start
        )

        guard case .connected(let descriptor) = outcome else {
            Issue.record("expected a connection, got \(outcome)")
            return
        }
        defer { close(descriptor) }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(peerPort(descriptor) == live.port)
        #expect(fcntl(descriptor, F_GETFL, 0) & O_NONBLOCK == 0)
    }

    @Test("A refused address starts the next attempt at once")
    func refusedAddressFallsThroughAtOnce() throws {
        let live = try #require(LoopbackListener())
        let started = ContinuousClock.now

        let outcome = SSHTransportDial.connect(
            [loopback(port: 1), live.address],
            deadline: started.advanced(by: .seconds(10)),
            interrupt: SSHDialInterrupt(),
            attemptDelay: .seconds(5)
        )

        guard case .connected(let descriptor) = outcome else {
            Issue.record("expected a connection, got \(outcome)")
            return
        }
        close(descriptor)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("Every address refused reports the last error")
    func everyAddressRefusedFails() {
        let outcome = SSHTransportDial.connect(
            [loopback(port: 1), loopback(port: 1)],
            deadline: .now.advanced(by: .seconds(5)),
            interrupt: SSHDialInterrupt()
        )

        #expect(outcome == .failed(lastErrno: ECONNREFUSED))
    }

    @Test("Every address black-holed times out at the shared deadline")
    func everyAddressBlackHoledTimesOut() throws {
        let blackHole = BlackHole()
        let started = ContinuousClock.now

        let outcome = SSHTransportDial.connect(
            [blackHole.address, blackHole.address],
            deadline: started.advanced(by: .milliseconds(600)),
            interrupt: SSHDialInterrupt(),
            start: blackHole.start
        )

        #expect(outcome == .timedOut)
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .milliseconds(600))
        #expect(elapsed < .seconds(2))
    }

    @Test("No address at all fails without an error")
    func noAddressFails() {
        let outcome = SSHTransportDial.connect([], deadline: .now.advanced(by: .seconds(1)), interrupt: SSHDialInterrupt())

        #expect(outcome == .failed(lastErrno: nil))
    }

    @Test("Firing the interrupt wakes a dial waiting on a black hole")
    func interruptWakesDial() async throws {
        let blackHole = BlackHole()
        let interrupt = SSHDialInterrupt()
        let started = ContinuousClock.now

        let dial = Task.detached {
            SSHTransportDial.connect(
                [blackHole.address],
                deadline: .now.advanced(by: .seconds(30)),
                interrupt: interrupt,
                start: blackHole.start
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        interrupt.fire()

        #expect(await dial.value == .interrupted)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("The families take turns, led by the first address's family")
    func familiesInterleave() {
        let v6a = address(family: AF_INET6, port: 1)
        let v6b = address(family: AF_INET6, port: 2)
        let v6c = address(family: AF_INET6, port: 3)
        let v4a = address(family: AF_INET, port: 4)

        let ordered = SSHTransportDial.interleavingFamilies([v6a, v6b, v6c, v4a])

        #expect(ordered.map(portOf) == [1, 4, 2, 3])
    }

    // MARK: - Helpers

    private func peerPort(_ descriptor: Int32) -> Int {
        var peer = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(descriptor, $0, &length) }
        }
        return Int(UInt16(bigEndian: peer.sin_port))
    }

    private func address(family: Int32, port: UInt16) -> SSHSocketAddress {
        var inet = sockaddr_in()
        inet.sin_family = sa_family_t(AF_INET)
        inet.sin_port = port.bigEndian
        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { destination in
            withUnsafeBytes(of: &inet) { destination.copyMemory(from: $0) }
        }
        return SSHSocketAddress(
            storage: storage,
            length: socklen_t(MemoryLayout<sockaddr_in>.size),
            family: family,
            socketType: SOCK_STREAM,
            socketProtocol: IPPROTO_TCP
        )
    }
}

private func loopback(port: UInt16) -> SSHSocketAddress {
    var inet = sockaddr_in()
    inet.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    inet.sin_family = sa_family_t(AF_INET)
    inet.sin_port = port.bigEndian
    inet.sin_addr.s_addr = inet_addr("127.0.0.1")
    var storage = sockaddr_storage()
    withUnsafeMutableBytes(of: &storage) { destination in
        withUnsafeBytes(of: &inet) { destination.copyMemory(from: $0) }
    }
    return SSHSocketAddress(
        storage: storage,
        length: socklen_t(MemoryLayout<sockaddr_in>.size),
        family: AF_INET,
        socketType: SOCK_STREAM,
        socketProtocol: IPPROTO_TCP
    )
}

private class LoopbackListener: @unchecked Sendable {
    let descriptor: Int32
    let port: UInt16
    var address: SSHSocketAddress { loopback(port: port) }

    init?(backlog: Int32 = 8) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var inet = sockaddr_in()
        inet.sin_family = sa_family_t(AF_INET)
        inet.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &inet) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, named == 0, listen(fd, backlog) == 0 else {
            close(fd)
            return nil
        }
        descriptor = fd
        port = UInt16(bigEndian: assigned.sin_port)
    }

    deinit {
        close(descriptor)
    }
}

// Stands in for an address that drops every SYN. macOS resets a connect to a full accept queue rather than
// dropping it, so the attempt it starts is a listening socket: one never turns writable and reports no error, as
// a connect that gets no answer never does. Any other address connects for real.
private final class BlackHole: Sendable {
    let address = loopback(port: 9)

    init() {}

    func start(_ target: SSHSocketAddress) -> SSHTransportDial.Start {
        guard portOf(target) == 9 else { return SSHTransportDial.startConnect(target) }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed(errno) }
        var inet = sockaddr_in()
        inet.sin_family = sa_family_t(AF_INET)
        inet.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &inet) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            return .failed(EIO)
        }
        return .inProgress(fd)
    }
}

private func portOf(_ address: SSHSocketAddress) -> Int {
    var storage = address.storage
    return withUnsafePointer(to: &storage) {
        $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin_port)) }
    }
}
