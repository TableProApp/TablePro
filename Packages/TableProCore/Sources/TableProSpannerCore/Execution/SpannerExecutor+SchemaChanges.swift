import Foundation

extension SpannerExecutor {
    func applySchemaChange(_ sql: String) async throws {
        let operation: SpannerOperation
        do {
            operation = try await client.updateDdl([sql])
        } catch {
            await typeCache.removeAll()
            throw error
        }
        await typeCache.removeAll()
        defer { Task { await self.typeCache.removeAll() } }
        try await waitForCompletion(of: operation)
    }

    private func waitForCompletion(of operation: SpannerOperation) async throws {
        if let error = operation.error {
            throw error
        }
        guard !operation.done else { return }
        let deadline = ddlDeadline().map { ContinuousClock.now.advanced(by: $0) }
        while true {
            do {
                try await Task.sleep(for: schemaChangePollInterval)
            } catch {
                throw SpannerExecutionError.schemaChangeStillRunning(operation: operation.name)
            }
            let current: SpannerOperation
            do {
                current = try await client.operation(named: operation.name)
            } catch {
                guard SpannerTransactionController.outcomeIsUnknown(after: error) else { throw error }
                throw SpannerExecutionError.schemaChangeStillRunning(operation: operation.name)
            }
            if let error = current.error {
                throw error
            }
            if current.done {
                return
            }
            if let deadline, ContinuousClock.now >= deadline {
                throw SpannerExecutionError.schemaChangeStillRunning(operation: operation.name)
            }
        }
    }
}
