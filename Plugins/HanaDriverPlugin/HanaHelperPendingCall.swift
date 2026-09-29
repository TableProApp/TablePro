import Foundation

struct HanaHelperCancelWatch: Equatable, Sendable {
    let ticket: HanaOperationTicket
    let issuedThrough: UInt64

    func covers(callID: UInt64, ticket callTicket: HanaOperationTicket?) -> Bool {
        guard let callTicket, callTicket.session == ticket.session else { return false }
        guard ticket.operation != 0 else { return callID <= issuedThrough }
        return callTicket.operation == ticket.operation
    }
}

final class HanaHelperPendingCall: @unchecked Sendable {
    let ticket: HanaOperationTicket?

    private let lock = NSLock()
    private let answered = DispatchSemaphore(value: 0)
    private var outcome: Result<Data, HanaBridgeFailure>?

    init(ticket: HanaOperationTicket?) {
        self.ticket = ticket
    }

    @discardableResult
    func complete(with outcome: Result<Data, HanaBridgeFailure>) -> Bool {
        let isFirstAnswer = lock.withLock { () -> Bool in
            guard self.outcome == nil else { return false }
            self.outcome = outcome
            return true
        }
        guard isFirstAnswer else { return false }
        answered.signal()
        return true
    }

    func wait() -> Result<Data, HanaBridgeFailure> {
        answered.wait()
        answered.signal()
        return recordedOutcome
    }

    func wait(until deadline: DispatchTime) -> Result<Data, HanaBridgeFailure>? {
        guard answered.wait(timeout: deadline) == .success else { return nil }
        answered.signal()
        return recordedOutcome
    }

    private var recordedOutcome: Result<Data, HanaBridgeFailure> {
        lock.withLock { outcome } ?? .failure(HanaBridgeFailure(kind: .internalFailure))
    }
}
