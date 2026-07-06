//
//  SSHChannelRelay.swift
//  TablePro
//

import Foundation

internal struct RelayDirections: OptionSet {
    let rawValue: Int32

    static let inbound = RelayDirections(rawValue: 1 << 0)
    static let outbound = RelayDirections(rawValue: 1 << 1)
}

internal enum ChannelReadResult: Equatable {
    case bytes(Int)
    case wouldBlock
    case closed
}

internal enum ChannelWriteResult: Equatable {
    case bytes(Int)
    case wouldBlock
    case closed
}

internal protocol SSHChannelIO {
    func read(into buffer: UnsafeMutablePointer<CChar>, count: Int) -> ChannelReadResult
    func write(_ buffer: UnsafePointer<CChar>, count: Int) -> ChannelWriteResult
    func blockDirections() -> RelayDirections
}

internal enum RelayTermination: Equatable {
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
internal struct SSHChannelRelay {
    let localFD: Int32
    let transportFD: Int32
    let channelIO: any SSHChannelIO
    let bufferSize: Int
    let isActive: () -> Bool

    private static let pollTimeoutMs: Int32 = 500
    private static let writeWaitTimeoutMs: Int32 = 1_000

    func run() -> RelayTermination {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while isActive() {
            var pollFDs = [
                pollfd(fd: localFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: transportFD, events: Int16(POLLIN), revents: 0),
            ]

            let pollResult = poll(&pollFDs, 2, Self.pollTimeoutMs)
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
                case .keepGoing: break
                case .channelClosed: return .channelClosed
                case .localClosed: return .localClosed
                case .transportHangup: return .transportHangup
                }
            }

            if localState == .readable || localState == .drainThenStop {
                switch pumpLocalToChannel(buffer) {
                case .keepGoing: break
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
        case keepGoing
        case channelClosed
        case localClosed
        case transportHangup
    }

    private enum TransportWait {
        case ready
        case hangup
    }

    private func pumpChannelToLocal(_ buffer: UnsafeMutablePointer<CChar>, transportReadable: Bool) -> PumpOutcome {
        switch channelIO.read(into: buffer, count: bufferSize) {
        case .bytes(let count):
            var totalSent = 0
            while totalSent < count {
                let sent = send(localFD, buffer.advanced(by: totalSent), count - totalSent, 0)
                if sent <= 0 { return .localClosed }
                totalSent += sent
            }
            return .keepGoing
        case .wouldBlock:
            if transportReadable, transportAtEOF() { return .transportHangup }
            return .keepGoing
        case .closed:
            return .channelClosed
        }
    }

    private func pumpLocalToChannel(_ buffer: UnsafeMutablePointer<CChar>) -> PumpOutcome {
        let localRead = recv(localFD, buffer, bufferSize, 0)
        if localRead <= 0 { return .localClosed }

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
        return .keepGoing
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
            switch relayFDState(pollFD.revents) {
            case .stop, .drainThenStop:
                return .hangup
            case .readable, .idle:
                return .ready
            }
        }
    }

    private func transportAtEOF() -> Bool {
        var byte: UInt8 = 0
        return recv(transportFD, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
    }
}
