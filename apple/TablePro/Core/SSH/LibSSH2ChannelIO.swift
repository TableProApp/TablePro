//
//  LibSSH2ChannelIO.swift
//  TablePro
//
//  Compiled into the macOS app and, by file reference, into the iOS app, which defaults to
//  MainActor isolation. Every top-level declaration states its own isolation for that reason;
//  the iOS build is the check.
//

import Foundation

import CLibSSH2
import TableProSSHTransport

// libssh2 is not thread-safe per session: the session's SSHSessionPump makes every call on its queue.
nonisolated internal struct LibSSH2ChannelIO: SSHChannelIO, @unchecked Sendable {
    let channel: OpaquePointer
    let session: OpaquePointer

    // libssh2 hands a transport error (-43 on EOF, -13 on DISCONNECT, -12, a failed re-key) to every channel call; only these end just one channel.
    private static let channelScopedErrors: Set<Int> = [
        Int(LIBSSH2_ERROR_CHANNEL_OUTOFORDER),
        Int(LIBSSH2_ERROR_CHANNEL_FAILURE),
        Int(LIBSSH2_ERROR_CHANNEL_REQUEST_DENIED),
        Int(LIBSSH2_ERROR_CHANNEL_UNKNOWN),
        Int(LIBSSH2_ERROR_CHANNEL_WINDOW_EXCEEDED),
        Int(LIBSSH2_ERROR_CHANNEL_PACKET_EXCEEDED),
        Int(LIBSSH2_ERROR_CHANNEL_CLOSED),
        Int(LIBSSH2_ERROR_CHANNEL_EOF_SENT),
        Int(LIBSSH2_ERROR_CHANNEL_WINDOW_FULL),
    ]

    static func readResult(_ returnCode: Int) -> ChannelReadResult {
        if returnCode > 0 { return .bytes(returnCode) }
        if returnCode == 0 { return .closed }
        if returnCode == Int(LIBSSH2_ERROR_EAGAIN) { return .wouldBlock }
        return channelScopedErrors.contains(returnCode) ? .closed : .transportFailed
    }

    static func writeResult(_ returnCode: Int) -> ChannelWriteResult {
        if returnCode > 0 { return .bytes(returnCode) }
        if returnCode == 0 { return .closed }
        if returnCode == Int(LIBSSH2_ERROR_EAGAIN) { return .wouldBlock }
        return channelScopedErrors.contains(returnCode) ? .closed : .transportFailed
    }

    // A read after the server's EOF answers EAGAIN only while its window adjust waits to send (channel.c,
    // ssh2_channel_read), and freeing the channel with that packet half sent leaves every later send refused.
    func read(into buffer: UnsafeMutablePointer<CChar>, count: Int) -> ChannelReadResult {
        let result = Int(tablepro_libssh2_channel_read(channel, buffer, count))
        if result == Int(LIBSSH2_ERROR_EAGAIN), libssh2_channel_eof(channel) != 0, !blockDirections().contains(.outbound) {
            return .closed
        }
        return Self.readResult(result)
    }

    func write(_ buffer: UnsafePointer<CChar>, count: Int) -> ChannelWriteResult {
        Self.writeResult(Int(tablepro_libssh2_channel_write(channel, buffer, count)))
    }

    func blockDirections() -> RelayDirections {
        RelayDirections(libssh2BlockDirections: libssh2_session_block_directions(session))
    }

    // read_avail counts the bytes another call already queued for this channel (channel.c, libssh2_channel_window_read_ex).
    func hasQueuedInput() -> Bool {
        var queued: UInt = 0
        _ = libssh2_channel_window_read_ex(channel, &queued, nil)
        return queued > 0 || libssh2_channel_eof(channel) != 0
    }

    // ssh2_channel_write answers EAGAIN with no window before it builds a packet, and with window once the packet is built.
    func hasSendWindow() -> Bool {
        libssh2_channel_window_write_ex(channel, nil) > 0
    }
}

nonisolated internal extension RelayDirections {
    init(libssh2BlockDirections directions: Int32) {
        var result: RelayDirections = []
        if directions & LIBSSH2_SESSION_BLOCK_INBOUND != 0 { result.insert(.inbound) }
        if directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { result.insert(.outbound) }
        self = result
    }
}
