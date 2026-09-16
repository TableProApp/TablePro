//
//  RemoteSQLiteExecChannelOpener.swift
//  TablePro
//

import CLibSSH2
import Foundation

/// Opens one session channel and starts a command on it, one non-blocking attempt at a time, so
/// `SSHForwardChannelOpenPump` can drive it to a decision within an app-owned deadline exactly as it
/// drives a forwarding open. A forwarding channel opens in a single call; an exec channel is two
/// steps, the channel open and the `exec` request, and either can report `LIBSSH2_ERROR_EAGAIN`, so
/// the phase is remembered between attempts.
///
/// The opener owns the channel until it hands it back as `.opened`. If the pump times out or is
/// cancelled after the channel was created but before it was handed over, the caller must call
/// `abort()` to free it, because dropping the Swift reference does not free the libssh2 channel and
/// the session stays live.
final class RemoteSQLiteExecChannelOpener: SSHForwardChannelOpening {
    private enum Phase {
        case opening
        case starting
        case configuring
        case finished
    }

    private let session: OpaquePointer
    private let command: String
    private let sessionQueue: DispatchQueue
    private var phase: Phase = .opening
    private var channel: OpaquePointer?

    init(session: OpaquePointer, command: String, sessionQueue: DispatchQueue) {
        self.session = session
        self.command = command
        self.sessionQueue = sessionQueue
    }

    func attemptOpen() -> SSHForwardChannelAttempt {
        sessionQueue.sync {
            switch phase {
            case .opening:
                return openChannel()
            case .starting:
                return startCommand()
            case .configuring:
                return configure()
            case .finished:
                return .failed(code: 0, message: "channel open already finished")
            }
        }
    }

    /// Frees a channel that was opened but never handed to the relay, for an open the pump timed out
    /// or cancelled. A no-op once the channel has been handed over or already freed.
    func abort() {
        sessionQueue.sync { freeChannel() }
    }

    private func openChannel() -> SSHForwardChannelAttempt {
        if let opened = libssh2_channel_open_ex(session, "session", 7, 2 * 1_024 * 1_024, 32_768, nil, 0) {
            channel = opened
            phase = .starting
            return startCommand()
        }
        return wouldBlockOrFailed()
    }

    private func startCommand() -> SSHForwardChannelAttempt {
        guard let channel else { return .failed(code: 0, message: "no channel to start a command on") }
        let rc = libssh2_channel_process_startup(channel, "exec", 4, command, UInt32(command.utf8.count))
        if rc == 0 {
            phase = .configuring
            return configure()
        }
        if rc == LIBSSH2_ERROR_EAGAIN {
            return .wouldBlock(RelayDirections(libssh2BlockDirections: libssh2_session_block_directions(session)))
        }
        let message = LibSSH2ForwardChannel.lastErrorMessage(session: session)
        freeChannel()
        return .failed(code: rc, message: message)
    }

    /// Discards the agent's standard error rather than merging it into the protocol stream. A merge
    /// would corrupt the framed replies; leaving it unread would let a large Python traceback fill
    /// the channel window and stall the relay, which reads standard output alone.
    private func configure() -> SSHForwardChannelAttempt {
        guard let channel else { return .failed(code: 0, message: "no channel to configure") }
        let rc = libssh2_channel_handle_extended_data2(channel, LIBSSH2_CHANNEL_EXTENDED_DATA_IGNORE)
        if rc == LIBSSH2_ERROR_EAGAIN {
            return .wouldBlock(RelayDirections(libssh2BlockDirections: libssh2_session_block_directions(session)))
        }
        self.channel = nil
        phase = .finished
        return .opened(channel)
    }

    private func wouldBlockOrFailed() -> SSHForwardChannelAttempt {
        let errorCode = libssh2_session_last_errno(session)
        guard errorCode == LIBSSH2_ERROR_EAGAIN else {
            return .failed(code: errorCode, message: LibSSH2ForwardChannel.lastErrorMessage(session: session))
        }
        return .wouldBlock(RelayDirections(libssh2BlockDirections: libssh2_session_block_directions(session)))
    }

    private func freeChannel() {
        if let channel {
            libssh2_channel_free(channel)
            self.channel = nil
        }
        phase = .finished
    }
}
