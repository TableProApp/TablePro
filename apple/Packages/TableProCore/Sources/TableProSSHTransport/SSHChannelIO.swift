//
//  SSHChannelIO.swift
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
    // The session is gone, not only this channel: the relay ends .transportHangup so the owner marks the tunnel dead now, not at the next keep-alive.
    case transportFailed
}

public enum ChannelWriteResult: Equatable, Sendable {
    case bytes(Int)
    case wouldBlock
    case closed
    case transportFailed
}

// One channel of a session, called only on its `SSHSessionPump`'s queue.
public protocol SSHChannelIO: Sendable {
    func read(into buffer: UnsafeMutablePointer<CChar>, count: Int) -> ChannelReadResult
    func write(_ buffer: UnsafePointer<CChar>, count: Int) -> ChannelWriteResult
    func blockDirections() -> RelayDirections
    // Data or an end of file another call on the session already took off the transport for this channel.
    func hasQueuedInput() -> Bool
    // Room left in the server's window for this channel's data. A `write` that answered `.wouldBlock` with
    // room has a packet on its way that only another `write` on this channel finishes; without room it waits
    // for the server to open the window.
    func hasSendWindow() -> Bool
}

public enum RelayTermination: Equatable, Sendable {
    case localClosed
    case transportHangup
    case channelClosed
    case cancelled
}
