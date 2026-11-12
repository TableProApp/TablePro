import Foundation

extension MainContentCoordinator {
    // The result paths run inside `MainActor.run` and cannot await the write; tests await the returned task.
    @discardableResult
    func recordHistory(_ request: QueryHistoryRecordRequest) -> Task<Bool, Never> {
        if request.source == .editor {
            if #available(macOS 14.0, *) {
                FeatureTipSignals.editorQueryRan()
            }
            if request.wasSuccessful {
                services.telemetry.queryExecuted(databaseType: request.databaseType.rawValue)
            }
        }
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
