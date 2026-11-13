//
//  SSHListenerAcceptor.swift
//  TableProSSHTransport
//

import Foundation
import os

public struct SSHAcceptedClient: Sendable {
    public let descriptor: Int32
    // Taken at accept, before any queue hop, since the client's own connect timeout is already running.
    public let acceptedAt: Date
}

// Accepts on a tunnel's listening socket only when the kernel reports a pending connection, so an
// idle listener costs no wakeups and parks no thread. GCD runs the cancel handler only after a
// running event handler has returned, so once `waitForCancellation()` returns nothing can accept on
// the descriptor and its owner may close it. The acceptor never closes it.
public final class SSHListenerAcceptor: @unchecked Sendable {
    private let source: any DispatchSourceRead
    private let isCancelled: OSAllocatedUnfairLock<Bool>
    private let cancelled: DispatchGroup

    public init(
        listenFD: Int32,
        queue: DispatchQueue,
        onAccept: @escaping @Sendable (SSHAcceptedClient) -> Void
    ) {
        // A drain then ends on EAGAIN instead of blocking the queue in accept.
        let flags = fcntl(listenFD, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(listenFD, F_SETFL, flags | O_NONBLOCK)
        }

        let isCancelled = OSAllocatedUnfairLock(initialState: false)
        let cancelled = DispatchGroup()
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { @Sendable in
            SSHListenerAcceptor.acceptPending(
                listenFD: listenFD,
                isCancelled: { isCancelled.withLock { $0 } },
                onAccept: onAccept
            )
        }
        cancelled.enter()
        source.setCancelHandler { @Sendable in
            cancelled.leave()
        }

        self.source = source
        self.isCancelled = isCancelled
        self.cancelled = cancelled
    }

    // libdispatch crashes on releasing a source that was never activated.
    deinit {
        cancel()
    }

    public func start() {
        source.activate()
    }

    public func cancel() {
        isCancelled.withLock { $0 = true }
        source.cancel()
        // A source cancelled before start runs its cancel handler only once active.
        source.activate()
    }

    public func waitForCancellation() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cancelled.notify(queue: .global(qos: .utility)) {
                continuation.resume()
            }
        }
    }

    private static func acceptPending(
        listenFD: Int32,
        isCancelled: () -> Bool,
        onAccept: (SSHAcceptedClient) -> Void
    ) {
        while !isCancelled() {
            let descriptor = accept(listenFD, nil, nil)
            guard descriptor >= 0 else {
                switch errno {
                case EINTR, ECONNABORTED:
                    continue
                default:
                    return
                }
            }
            let acceptedAt = Date()
            // Darwin hands the listener's O_NONBLOCK to the accepted socket, and the Remote SQLite admission read blocks on it.
            let flags = fcntl(descriptor, F_GETFL, 0)
            if flags >= 0 {
                _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK)
            }
            onAccept(SSHAcceptedClient(descriptor: descriptor, acceptedAt: acceptedAt))
        }
    }
}
