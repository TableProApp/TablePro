//
//  LibSSH2JumpRelay.swift
//  TablePro
//
//  Compiled into the macOS app and, by file reference, into the iOS app, which defaults to
//  MainActor isolation. Every declaration states its own isolation for that reason; the iOS
//  build is the check.
//

import Foundation

import TableProSSHTransport

nonisolated internal enum LibSSH2JumpRelay {
    // The hop's pump is the only thing that touches these once it starts, which the compiler cannot see
    // through an OpaquePointer.
    nonisolated private struct Handles: @unchecked Sendable {
        let channel: OpaquePointer
        let session: OpaquePointer
    }

    // The hop session carries one channel, relayed to `localFD`, which the pump closes. The fence finishes once
    // the pump has stopped, so teardown frees the channel and session only after the pump's last libssh2 call.
    static func start(
        channel: OpaquePointer,
        localFD: Int32,
        transportFD: Int32,
        session: OpaquePointer,
        sessionQueue: DispatchQueue
    ) -> SSHJumpRelayFence {
        let handles = Handles(channel: channel, session: session)
        let pump = SSHSessionPump(transportFD: transportFD, queue: sessionQueue)
        let fence = SSHJumpRelayFence {
            pump.stop()
        }
        pump.whenStopped {
            fence.finish()
        }
        pump.relay(
            localFD: localFD,
            channel: LibSSH2ChannelIO(channel: handles.channel, session: handles.session),
            bufferSize: 32_768
        ) { _ in
            pump.stop()
        }
        return fence
    }
}
