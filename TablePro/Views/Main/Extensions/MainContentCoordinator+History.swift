import Foundation

extension MainContentCoordinator {
    /// The result-application paths run synchronously inside `MainActor.run`, so they cannot await
    /// the write. Returning the task keeps it owned and awaitable instead of orphaned, which is
    /// what tests use to observe the record without polling.
    @discardableResult
    func recordHistory(_ request: QueryHistoryRecordRequest) -> Task<Bool, Never> {
        let recorder = services.queryHistoryManager
        return Task(priority: .utility) {
            await recorder.record(request)
        }
    }
}

extension QueryExecutionCoordinator {
    @discardableResult
    func recordHistory(_ request: QueryHistoryRecordRequest) -> Task<Bool, Never> {
        parent.recordHistory(request)
    }
}
