//
//  SSHJumpRelayFence.swift
//  TableProSSHTransport
//

import Foundation
import os

// Cancelling a Swift task does not cancel the GCD block that runs a hop's `SSHChannelRelay`, so
// teardown wakes its descriptors and waits here for its last libssh2 call before freeing the channel
// or session. The stop action and the relay's final close share one lock, so a late stop cannot
// `shutdown` a descriptor number the kernel already handed to someone else.
public final class SSHJumpRelayFence: @unchecked Sendable {
    private struct State {
        var stopAction: (@Sendable () -> Void)?
        var isFinished = false
    }

    private let state: OSAllocatedUnfairLock<State>
    private let completion = DispatchGroup()

    public init(stopAction: @escaping @Sendable () -> Void) {
        state = OSAllocatedUnfairLock(initialState: State(stopAction: stopAction))
        completion.enter()
    }

    public var isActive: Bool {
        state.withLock { $0.stopAction != nil && !$0.isFinished }
    }

    public func stop() {
        state.withLock { state in
            guard let stopAction = state.stopAction, !state.isFinished else { return }
            state.stopAction = nil
            stopAction()
        }
    }

    public func finish(cleanup: @Sendable () -> Void = {}) {
        let didFinish = state.withLock { state -> Bool in
            guard !state.isFinished else { return false }
            state.stopAction = nil
            state.isFinished = true
            cleanup()
            return true
        }
        if didFinish {
            completion.leave()
        }
    }

    public func wait() {
        completion.wait()
    }

    public func waitForCompletion() async {
        await withCheckedContinuation { continuation in
            completion.notify(queue: .global(qos: .utility)) {
                continuation.resume()
            }
        }
    }
}
