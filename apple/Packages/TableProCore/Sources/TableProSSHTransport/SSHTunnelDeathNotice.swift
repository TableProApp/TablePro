//
//  SSHTunnelDeathNotice.swift
//  TableProSSHTransport
//

import Foundation
import os

// A tunnel starts its keep-alive before its owner can listen, so a handler set after the death runs
// at once instead of missing it. Each death is reported once.
public final class SSHTunnelDeathNotice: Sendable {
    private struct State {
        var died = false
        var handler: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func onDeath(_ handler: @escaping @Sendable () -> Void) {
        let diedAlready = state.withLock { state -> Bool in
            guard !state.died else { return true }
            state.handler = handler
            return false
        }
        if diedAlready { handler() }
    }

    public func died() {
        let handler = state.withLock { state -> (@Sendable () -> Void)? in
            guard !state.died else { return nil }
            state.died = true
            defer { state.handler = nil }
            return state.handler
        }
        handler?()
    }
}
