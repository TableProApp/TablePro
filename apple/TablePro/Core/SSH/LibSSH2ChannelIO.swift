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

// Every call goes through the serial sessionQueue: libssh2 is not thread-safe per session.
nonisolated internal struct LibSSH2ChannelIO: SSHChannelIO {
    let channel: OpaquePointer
    let session: OpaquePointer
    let sessionQueue: DispatchQueue

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

    func read(into buffer: UnsafeMutablePointer<CChar>, count: Int) -> ChannelReadResult {
        let result = sessionQueue.sync { Int(tablepro_libssh2_channel_read(channel, buffer, count)) }
        if result == Int(LIBSSH2_ERROR_EAGAIN), sessionQueue.sync(execute: { libssh2_channel_eof(channel) }) != 0 {
            return .closed
        }
        return Self.readResult(result)
    }

    func write(_ buffer: UnsafePointer<CChar>, count: Int) -> ChannelWriteResult {
        Self.writeResult(sessionQueue.sync { Int(tablepro_libssh2_channel_write(channel, buffer, count)) })
    }

    func blockDirections() -> RelayDirections {
        RelayDirections(libssh2BlockDirections: sessionQueue.sync { libssh2_session_block_directions(session) })
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
