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
    // The relay is the only thing that touches these once it starts, which the compiler cannot see
    // through an OpaquePointer.
    nonisolated private struct Handles: @unchecked Sendable {
        let channel: OpaquePointer
        let session: OpaquePointer
    }

    static func start(
        channel: OpaquePointer,
        localFD: Int32,
        transportFD: Int32,
        session: OpaquePointer,
        sessionQueue: DispatchQueue
    ) -> SSHJumpRelayFence {
        let relayQueue = DispatchQueue(
            label: "com.TablePro.ssh.hop-relay",
            qos: .utility
        )
        let handles = Handles(channel: channel, session: session)
        let fence = SSHJumpRelayFence {
            shutdown(localFD, SHUT_RDWR)
            shutdown(transportFD, SHUT_RDWR)
        }
        relayQueue.async {
            defer {
                fence.finish {
                    shutdown(localFD, SHUT_RDWR)
                    Darwin.close(localFD)
                }
            }

            let relay = SSHChannelRelay(
                localFD: localFD,
                transportFD: transportFD,
                channelIO: LibSSH2ChannelIO(
                    channel: handles.channel,
                    session: handles.session,
                    sessionQueue: sessionQueue
                ),
                bufferSize: 32_768,
                isActive: { fence.isActive }
            )

            _ = relay.run()
        }
        return fence
    }
}
