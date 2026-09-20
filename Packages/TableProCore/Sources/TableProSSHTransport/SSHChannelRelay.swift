//
//  SSHChannelRelay.swift
//  TableProSSHTransport
//

import Foundation

public struct RelayDirections: OptionSet, Sendable {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let inbound = RelayDirections(rawValue: 1 << 0)
    public static let outbound = RelayDirections(rawValue: 1 << 1)
}

public enum ChannelReadResult: Equatable, Sendable {
    case bytes(Int)
    case wouldBlock
    case closed
}

public enum ChannelWriteResult: Equatable, Sendable {
    case bytes(Int)
    case wouldBlock
    case closed
}

public protocol SSHChannelIO {
    func read(into buffer: UnsafeMutablePointer<CChar>, count: Int) -> ChannelReadResult
    func write(_ buffer: UnsafePointer<CChar>, count: Int) -> ChannelWriteResult
    func blockDirections() -> RelayDirections
}

public enum RelayTermination: Equatable, Sendable {
    case localClosed
    case transportHangup
    case channelClosed
    case cancelled
}

/// Bidirectional relay between a local socket fd and an SSH channel.
/// Polls the local fd and the SSH transport fd, draining buffered data before
/// tearing down on hangup so the last bytes are not dropped. Hangup and error
/// on either fd terminate the loop instead of spinning on a permanently
/// poll-ready, closed fd. Because libssh2 reports EAGAIN rather than a channel
/// close when only the transport dies, a transport that polls readable but is
/// at EOF is detected directly so a half-closed transport cannot spin.
public struct SSHChannelRelay {
    public let localFD: Int32
    public let transportFD: Int32
    public let channelIO: any SSHChannelIO
    public let bufferSize: Int
    public let isActive: () -> Bool

    /// Counts what crosses this relay, for the connection activity readout. Absent for a jump hop,
    /// whose relay carries the same payload a second time on its way to the next hop: counting both
    /// would report every byte twice for a connection that goes through a bastion.
    public var byteCounter: (any RelayByteObserver)?

    public init(
        localFD: Int32,
        transportFD: Int32,
        channelIO: any SSHChannelIO,
        bufferSize: Int,
        isActive: @escaping () -> Bool,
        byteCounter: (any RelayByteObserver)? = nil
    ) {
        self.localFD = localFD
        self.transportFD = transportFD
        self.channelIO = channelIO
        self.bufferSize = bufferSize
        self.isActive = isActive
        self.byteCounter = byteCounter
    }

    private static let pollTimeoutMs: Int32 = 500
    private static let writeWaitTimeoutMs: Int32 = 1_000

    /// How many channel reads one pump round may make before looking at the local fd again.
    ///
    /// libssh2 buffers whole SSH packets as it decrypts them, so a channel that has fallen behind
    /// holds more than one buffer's worth and the transport reports nothing new until that backlog
    /// is drained. Reading one buffer per poll round pays the 500ms timeout for every buffer, which
    /// measured 1,504ms for 98,304 queued bytes against a real sshd where draining took 502ms.
    /// The cap is what keeps a server that streams without pause from starving local to channel;
    /// a round that ends on the cap rather than on EAGAIN polls with no timeout, so the cap costs
    /// one round trip through `poll` and never a wait.
    private static let maxChannelReadsPerRound = 16

    public func run() -> RelayTermination {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var pollTimeoutMs = Self.pollTimeoutMs

        while isActive() {
            var pollFDs = [
                pollfd(fd: localFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: transportFD, events: Int16(POLLIN), revents: 0),
            ]

            let pollResult = poll(&pollFDs, 2, pollTimeoutMs)
            pollTimeoutMs = Self.pollTimeoutMs
            if pollResult < 0 {
                if errno == EINTR { continue }
                return .cancelled
            }

            let localState = relayFDState(pollFDs[0].revents)
            let transportState = relayFDState(pollFDs[1].revents)

            if transportState == .stop { return .transportHangup }
            if localState == .stop { return .localClosed }

            if transportState != .idle || pollResult == 0 {
                switch pumpChannelToLocal(buffer, transportReadable: transportState != .idle) {
                case .drained: break
                case .cappedWithMoreQueued: pollTimeoutMs = 0
                case .channelClosed: return .channelClosed
                case .localClosed: return .localClosed
                case .transportHangup: return .transportHangup
                }
            }

            if localState == .readable || localState == .drainThenStop {
                switch pumpLocalToChannel(buffer) {
                case .drained, .cappedWithMoreQueued: break
                case .channelClosed: return .channelClosed
                case .localClosed: return .localClosed
                case .transportHangup: return .transportHangup
                }
            }

            if transportState == .drainThenStop { return .transportHangup }
            if localState == .drainThenStop { return .localClosed }
        }

        return .cancelled
    }

    private enum PumpOutcome {
        case drained
        case cappedWithMoreQueued
        case channelClosed
        case localClosed
        case transportHangup
    }

    private enum TransportWait {
        case ready
        case hangup
    }

    private func pumpChannelToLocal(_ buffer: UnsafeMutablePointer<CChar>, transportReadable: Bool) -> PumpOutcome {
        for _ in 0 ..< Self.maxChannelReadsPerRound {
            switch channelIO.read(into: buffer, count: bufferSize) {
            case .bytes(let count):
                byteCounter?.recordReceived(count)
                guard sendToLocal(buffer, count: count) else { return .localClosed }
            case .wouldBlock:
                if transportReadable, transportAtEOF() { return .transportHangup }
                return .drained
            case .closed:
                return .channelClosed
            }
        }
        return .cappedWithMoreQueued
    }

    private func sendToLocal(_ buffer: UnsafeMutablePointer<CChar>, count: Int) -> Bool {
        var totalSent = 0
        while totalSent < count {
            let sent = send(localFD, buffer.advanced(by: totalSent), count - totalSent, 0)
            if sent <= 0 { return false }
            totalSent += sent
        }
        return true
    }

    private func pumpLocalToChannel(_ buffer: UnsafeMutablePointer<CChar>) -> PumpOutcome {
        let localRead = recv(localFD, buffer, bufferSize, 0)
        if localRead <= 0 { return .localClosed }
        byteCounter?.recordSent(localRead)

        var totalWritten = 0
        while totalWritten < Int(localRead) {
            switch channelIO.write(buffer.advanced(by: totalWritten), count: Int(localRead) - totalWritten) {
            case .bytes(let count):
                totalWritten += count
            case .wouldBlock:
                switch waitForTransport(channelIO.blockDirections()) {
                case .ready: break
                case .hangup: return .transportHangup
                }
            case .closed:
                return .channelClosed
            }
        }
        return .drained
    }

    private func waitForTransport(_ directions: RelayDirections) -> TransportWait {
        var events: Int16 = 0
        if directions.contains(.inbound) { events |= Int16(POLLIN) }
        if directions.contains(.outbound) { events |= Int16(POLLOUT) }
        guard events != 0 else { return .ready }

        while true {
            var pollFD = pollfd(fd: transportFD, events: events, revents: 0)
            let rc = poll(&pollFD, 1, Self.writeWaitTimeoutMs)
            if rc < 0 {
                if errno == EINTR { continue }
                return .hangup
            }
            switch transportPollOutcome(revents: pollFD.revents, requestedEvents: events) {
            case .hangup:
                return .hangup
            case .ready:
                return .ready
            case .timedOut:
                guard isActive() else { return .hangup }
            }
        }
    }

    private func transportAtEOF() -> Bool {
        var byte: UInt8 = 0
        return recv(transportFD, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
    }
}
