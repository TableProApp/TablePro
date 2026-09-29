import Foundation

struct HanaOperationTicket: Hashable, Sendable {
    let session: UInt64
    let operation: UInt64
}

protocol HanaOperationQueue: Sendable {
    func submit(_ work: @escaping @Sendable () -> Void)
}

extension DispatchQueue: HanaOperationQueue {
    func submit(_ work: @escaping @Sendable () -> Void) {
        async(execute: work)
    }
}

final class HanaOperationSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var ticket: HanaOperationTicket?
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func assign(_ ticket: HanaOperationTicket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.ticket = ticket
        return true
    }

    func cancel() -> HanaOperationTicket? {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return nil }
        cancelled = true
        return ticket
    }
}

final class HanaOpenInterruption: @unchecked Sendable {
    private let lock = NSLock()
    private var interrupted = false
    private var response: (@Sendable () -> Void)?

    var isInterrupted: Bool {
        lock.withLock { interrupted }
    }

    func interrupt() {
        let pending = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !interrupted else { return nil }
            interrupted = true
            let pending = response
            response = nil
            return pending
        }
        pending?()
    }

    func whenInterrupted(_ response: @escaping @Sendable () -> Void) -> Bool {
        lock.withLock {
            guard !interrupted else { return false }
            self.response = response
            return true
        }
    }

    func stopWatching() {
        lock.withLock { response = nil }
    }
}
