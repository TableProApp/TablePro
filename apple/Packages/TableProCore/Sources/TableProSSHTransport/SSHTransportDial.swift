//
//  SSHTransportDial.swift
//  TableProSSHTransport
//

import Foundation
import os

public struct SSHSocketAddress: @unchecked Sendable {
    public let storage: sockaddr_storage
    public let length: socklen_t
    public let family: Int32
    public let socketType: Int32
    public let socketProtocol: Int32

    public init(storage: sockaddr_storage, length: socklen_t, family: Int32, socketType: Int32, socketProtocol: Int32) {
        self.storage = storage
        self.length = length
        self.family = family
        self.socketType = socketType
        self.socketProtocol = socketProtocol
    }

    public var isIPv6: Bool { family == AF_INET6 }

    // Copies every entry of a getaddrinfo list, in its order, so the caller can free the list.
    public static func list(from first: UnsafeMutablePointer<addrinfo>) -> [SSHSocketAddress] {
        var addresses: [SSHSocketAddress] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let address = current {
            if let source = address.pointee.ai_addr {
                var storage = sockaddr_storage()
                let byteCount = min(Int(address.pointee.ai_addrlen), MemoryLayout<sockaddr_storage>.size)
                withUnsafeMutableBytes(of: &storage) { destination in
                    destination.copyBytes(from: UnsafeRawBufferPointer(start: source, count: byteCount))
                }
                addresses.append(SSHSocketAddress(
                    storage: storage,
                    length: address.pointee.ai_addrlen,
                    family: address.pointee.ai_family,
                    socketType: address.pointee.ai_socktype,
                    socketProtocol: address.pointee.ai_protocol
                ))
            }
            current = address.pointee.ai_next
        }
        return addresses
    }
}

// Wakes a dial waiting in poll. The pipe closes only when the last holder lets go, so a fire that races the
// dial's return writes to this pipe and never to a descriptor number the kernel has handed to another socket.
public final class SSHDialInterrupt: @unchecked Sendable {
    fileprivate let readFD: Int32
    private let writeFD: Int32
    private let fired = OSAllocatedUnfairLock(initialState: false)

    public init() {
        var fds: [Int32] = [-1, -1]
        if pipe(&fds) == 0 {
            for fd in fds {
                let flags = fcntl(fd, F_GETFL, 0)
                if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
            }
        }
        readFD = fds[0]
        writeFD = fds[1]
    }

    deinit {
        if readFD >= 0 { Darwin.close(readFD) }
        if writeFD >= 0 { Darwin.close(writeFD) }
    }

    public var isFired: Bool { fired.withLock { $0 } }

    public func fire() {
        let first = fired.withLock { wasFired -> Bool in
            defer { wasFired = true }
            return !wasFired
        }
        guard first, writeFD >= 0 else { return }
        var byte: UInt8 = 1
        _ = write(writeFD, &byte, 1)
    }
}

public enum SSHDialOutcome: Equatable, Sendable {
    // A blocking socket, connected; the caller owns it.
    case connected(Int32)
    // Every address failed; the errno of the last failure, or nil when there was no address.
    case failed(lastErrno: Int32?)
    case timedOut
    case interrupted
}

// Happy Eyeballs, RFC 8305: the address families alternate, a new attempt starts every 250 ms or as soon as one
// fails, every attempt shares the one deadline, and the first to connect wins while the rest are closed. A
// black-holed first address then costs one attempt delay instead of the whole connect timeout. The core dials the
// same way (core/crates/net/src/dial.rs).
public enum SSHTransportDial {
    // RFC 8305, section 5: the recommended Connection Attempt Delay.
    public static let attemptDelay: Duration = .milliseconds(250)

    // RFC 8305, section 4: the first address's family leads, then the families take turns.
    public static func interleavingFamilies(_ addresses: [SSHSocketAddress]) -> [SSHSocketAddress] {
        guard let firstIsV6 = addresses.first?.isIPv6 else { return addresses }
        var preferred = addresses.filter { $0.isIPv6 == firstIsV6 }.makeIterator()
        var other = addresses.filter { $0.isIPv6 != firstIsV6 }.makeIterator()
        var ordered: [SSHSocketAddress] = []
        ordered.reserveCapacity(addresses.count)
        while true {
            let next = (preferred.next(), other.next())
            if next.0 == nil, next.1 == nil { return ordered }
            if let address = next.0 { ordered.append(address) }
            if let address = next.1 { ordered.append(address) }
        }
    }

    // How one attempt begins: a connected socket, one still connecting (the dial owns it either way), or the
    // errno it failed with.
    public enum Start {
        case connected(Int32)
        case inProgress(Int32)
        case failed(Int32)
    }

    // Blocks the calling thread until an address connects, every one fails, the deadline passes or `interrupt`
    // fires, so it belongs on a dispatch queue, never on Swift's cooperative pool.
    public static func connect(
        _ addresses: [SSHSocketAddress],
        deadline: ContinuousClock.Instant,
        interrupt: SSHDialInterrupt,
        attemptDelay: Duration = attemptDelay,
        start: (SSHSocketAddress) -> Start = startConnect
    ) -> SSHDialOutcome {
        var waiting = interleavingFamilies(addresses)[...]
        var inFlight: [Int32] = []
        var lastErrno: Int32?
        var nextStart = ContinuousClock.now
        defer { inFlight.forEach { Darwin.close($0) } }

        while true {
            if interrupt.isFired { return .interrupted }
            let now = ContinuousClock.now
            guard now < deadline else {
                return inFlight.isEmpty && waiting.isEmpty && lastErrno != nil ? .failed(lastErrno: lastErrno) : .timedOut
            }

            if now >= nextStart, let address = waiting.popFirst() {
                switch start(address) {
                case .connected(let descriptor):
                    return .connected(descriptor)
                case .inProgress(let descriptor):
                    inFlight.append(descriptor)
                    nextStart = now.advanced(by: attemptDelay)
                case .failed(let error):
                    lastErrno = error
                    nextStart = now
                }
                continue
            }
            guard !inFlight.isEmpty else {
                if waiting.isEmpty { return .failed(lastErrno: lastErrno) }
                continue
            }

            var descriptors = inFlight.map { pollfd(fd: $0, events: Int16(POLLOUT), revents: 0) }
            descriptors.append(pollfd(fd: interrupt.readFD, events: Int16(POLLIN), revents: 0))
            let wakeAt = waiting.isEmpty ? deadline : min(deadline, nextStart)
            let ready = poll(&descriptors, nfds_t(descriptors.count), milliseconds(until: wakeAt))
            if ready < 0 {
                if errno == EINTR { continue }
                return .failed(lastErrno: errno)
            }
            if descriptors[descriptors.count - 1].revents != 0 { return .interrupted }

            var index = 0
            while index < inFlight.count {
                guard descriptors[index].revents != 0 else {
                    index += 1
                    continue
                }
                let descriptor = inFlight[index]
                inFlight.remove(at: index)
                descriptors.remove(at: index)
                var socketError: Int32 = 0
                var errorLength = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) != 0 {
                    socketError = errno
                }
                if socketError == 0 {
                    setBlocking(descriptor)
                    return .connected(descriptor)
                }
                Darwin.close(descriptor)
                lastErrno = socketError
                // RFC 8305: a failed attempt starts the next one at once rather than after the delay.
                nextStart = ContinuousClock.now
            }
        }
    }

    // A non-blocking connect.
    public static func startConnect(_ address: SSHSocketAddress) -> Start {
        let descriptor = socket(address.family, address.socketType, address.socketProtocol)
        guard descriptor >= 0 else { return .failed(errno) }
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

        var storage = address.storage
        let result = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, address.length)
            }
        }
        if result == 0 {
            setBlocking(descriptor)
            return .connected(descriptor)
        }
        let error = errno
        guard error == EINPROGRESS else {
            Darwin.close(descriptor)
            return .failed(error)
        }
        return .inProgress(descriptor)
    }

    private static func setBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) }
    }

    // Rounded up, so a wait never ends a moment early and spins.
    private static func milliseconds(until instant: ContinuousClock.Instant) -> Int32 {
        let remaining = ContinuousClock.now.duration(to: instant)
        guard remaining > .zero else { return 0 }
        let parts = remaining.components
        let milliseconds = parts.seconds * 1_000 + (parts.attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
        return Int32(clamping: milliseconds)
    }
}
