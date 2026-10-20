import CLibSSH2
import Foundation
import TableProSSHTransport

// `@unchecked`: the libssh2 handles are touched only on `sessionQueue`, and only by the relay until
// its fence has finished.
nonisolated struct SSHJumpHop: @unchecked Sendable {
    let session: OpaquePointer
    let socketFD: Int32
    let channel: OpaquePointer
    let relay: SSHJumpRelayFence
    let sessionQueue: DispatchQueue
}

nonisolated enum SSHJumpChain {
    // The Mac's order: wake every relay, wait until none can reach its handles, then free them.
    static func tearDown(_ hops: [SSHJumpHop], free: (SSHJumpHop) -> Void = SSHJumpChain.freeHandles(_:)) async {
        let ordered = Array(hops.reversed())
        for hop in ordered {
            hop.relay.stop()
            shutdown(hop.socketFD, SHUT_RDWR)
        }
        for hop in ordered {
            await hop.relay.waitForCompletion()
        }
        for hop in ordered {
            free(hop)
        }
    }

    static func freeHandles(_ hop: SSHJumpHop) {
        hop.sessionQueue.sync {
            libssh2_channel_free(hop.channel)
            tablepro_libssh2_session_disconnect(hop.session, "Closing tunnel")
            libssh2_session_free(hop.session)
        }
        Darwin.close(hop.socketFD)
    }
}
