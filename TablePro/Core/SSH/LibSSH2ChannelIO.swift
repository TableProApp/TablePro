//
//  LibSSH2ChannelIO.swift
//  TablePro
//

import Foundation

import CLibSSH2

/// Routes channel reads/writes through the serial `sessionQueue` because libssh2
/// is not thread-safe per session. Maps libssh2 return codes to the transport
/// agnostic results consumed by `SSHChannelRelay`.
internal struct LibSSH2ChannelIO: SSHChannelIO {
    let channel: OpaquePointer
    let session: OpaquePointer
    let sessionQueue: DispatchQueue

    func read(into buffer: UnsafeMutablePointer<CChar>, count: Int) -> ChannelReadResult {
        let result = sessionQueue.sync { Int(tablepro_libssh2_channel_read(channel, buffer, count)) }
        if result > 0 { return .bytes(result) }
        if result == 0 { return .closed }
        if sessionQueue.sync(execute: { libssh2_channel_eof(channel) }) != 0 { return .closed }
        if result == Int(LIBSSH2_ERROR_EAGAIN) { return .wouldBlock }
        return .closed
    }

    func write(_ buffer: UnsafePointer<CChar>, count: Int) -> ChannelWriteResult {
        let result = sessionQueue.sync { Int(tablepro_libssh2_channel_write(channel, buffer, count)) }
        if result > 0 { return .bytes(result) }
        if result == Int(LIBSSH2_ERROR_EAGAIN) { return .wouldBlock }
        return .closed
    }

    func blockDirections() -> RelayDirections {
        let directions = sessionQueue.sync { libssh2_session_block_directions(session) }
        var result: RelayDirections = []
        if directions & LIBSSH2_SESSION_BLOCK_INBOUND != 0 { result.insert(.inbound) }
        if directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { result.insert(.outbound) }
        return result
    }
}
