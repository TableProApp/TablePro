import Foundation
import os

/// Which calls on one SQL Server connection a Stop reaches, and when the thread reading the connection has to be
/// interrupted for it.
///
/// Every call is numbered as it is handed to the connection's queue, and a Stop cancels every call numbered so far. A
/// call therefore sees a Stop pressed while it waited behind another call, and never one pressed before it was made.
///
/// A Stop never calls db-lib itself. `dbcancel` sends the attention and then reads the server's answer on the calling
/// thread, and one called from another thread while the queue was inside `dbnextrow` left the queue waiting forever for
/// packets the Stop had already read: measured on the shipped FreeTDS 1.4.22, the queue sat in `tds_read_packet` on a
/// condition with no timeout. So a Stop only marks the calls, and while a call's request is on the wire it also raises
/// an interrupt. The reading thread looks for the mark after every db-lib call, and db-lib asks its interrupt handler
/// once a second while it waits on the socket, so the one thread that reads the connection is the one that ends the
/// request.
///
/// The interrupt is taken once, so it leads to one attention, and it ends with the request that raised it, so it never
/// reaches the next one.
public final class MSSQLRequestGate: Sendable {
    private struct State {
        var enqueuedCalls: UInt64 = 0
        var cancelledThroughCall: UInt64 = 0
        var requestInFlight = false
        var interruptRaised = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Numbers a call as it is handed to the queue.
    public func enqueue() -> UInt64 {
        state.withLock { state in
            state.enqueuedCalls += 1
            return state.enqueuedCalls
        }
    }

    /// Cancels every call numbered so far, and interrupts the one whose request is on the wire.
    public func stop() {
        state.withLock { state in
            state.cancelledThroughCall = state.enqueuedCalls
            if state.requestInFlight {
                state.interruptRaised = true
            }
        }
    }

    /// The last look for a Stop before `call` sends anything. A Stop is either seen here, and nothing is sent, or
    /// lands after it and interrupts the request.
    public func beginRequest(_ call: UInt64) throws {
        try state.withLock { state in
            guard call > state.cancelledThroughCall else { throw CancellationError() }
            state.requestInFlight = true
            state.interruptRaised = false
        }
    }

    public func endRequest() {
        state.withLock { state in
            state.requestInFlight = false
            state.interruptRaised = false
        }
    }

    public func isCancelled(_ call: UInt64) -> Bool {
        state.withLock { call <= $0.cancelledThroughCall }
    }

    /// What db-lib's interrupt handler answers while the reading thread waits on the socket.
    public var isInterruptRaised: Bool {
        state.withLock { $0.interruptRaised }
    }

    /// db-lib reports an interrupted wait as a timeout, and only a timeout this answers yes for becomes an attention.
    public func takeInterrupt() -> Bool {
        state.withLock { state in
            let raised = state.interruptRaised
            state.interruptRaised = false
            return raised
        }
    }
}
