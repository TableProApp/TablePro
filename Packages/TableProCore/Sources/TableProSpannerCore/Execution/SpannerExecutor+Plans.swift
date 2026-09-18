import Foundation

extension SpannerExecutor {
    public func explain(_ statement: SpannerRenderedStatement) async throws -> SpannerQueryOutcome {
        try ensureOpen()
        let kind = SpannerStatementClassifier.classify(statement.sql, dialect: dialect)
        let plan: SpannerQueryPlan?
        switch kind {
        case .query:
            plan = try await queryPlan(statement.sql)
        case .dml:
            plan = try await dmlPlan(statement.sql)
        case .explain(_, let analyze):
            throw analyze ? SpannerExecutionError.explainAnalyzeNotSupported : SpannerExecutionError.explainNotSupported(kind)
        default:
            throw SpannerExecutionError.explainNotSupported(kind)
        }
        let field = SpannerField(name: SpannerPlanRenderer.columnName, type: SpannerType(code: "STRING"))
        let rows = SpannerPlanRenderer.lines(plan).map { [SpannerCell.text($0)] }
        return SpannerQueryOutcome(fields: [field], rows: rows, rowsAffected: nil, kind: .explain(statement: statement.sql, analyze: false))
    }

    private func queryPlan(_ sql: String) async throws -> SpannerQueryPlan? {
        let request = SpannerExecuteSqlRequest(sql: sql, transaction: .singleUseStrongReadOnly, queryMode: .plan)
        let result = try await onReadSession { session in
            try await self.client.executeSql(session: session, request)
        }
        return result.stats?.queryPlan
    }

    private func dmlPlan(_ sql: String) async throws -> SpannerQueryPlan? {
        if await transactions.isIdle {
            return try await dmlPlanInThrowawayTransaction(sql)
        }
        return try await transactions.queue.run {
            switch try await self.transactions.claim() {
            case .idle:
                return try await self.dmlPlanInThrowawayTransaction(sql)
            case .open(let context):
                return try await self.dmlPlanInTransaction(sql, context: context)
            }
        }
    }

    private func dmlPlanInTransaction(_ sql: String, context: SpannerTransactionContext) async throws -> SpannerQueryPlan? {
        do {
            let seqno = try await transactions.nextSeqno(for: context)
            let request = SpannerExecuteSqlRequest(sql: sql, transaction: .id(context.transactionId), queryMode: .plan, seqno: seqno)
            return try await client.executeSql(session: context.session, request).stats?.queryPlan
        } catch let error as SpannerAPIError where error.isAborted || error.isSessionNotFound {
            await transactions.markAborted(context)
            throw error
        }
    }

    private func dmlPlanInThrowawayTransaction(_ sql: String) async throws -> SpannerQueryPlan? {
        do {
            return try await dmlPlanOnLeasedSession(sql)
        } catch let error as SpannerAPIError where error.isSessionNotFound {
            return try await dmlPlanOnLeasedSession(sql)
        }
    }

    private func dmlPlanOnLeasedSession(_ sql: String) async throws -> SpannerQueryPlan? {
        let session = try await sessions.leaseWriteSession()
        let request = SpannerExecuteSqlRequest(sql: sql, transaction: .beginReadWrite, queryMode: .plan, seqno: 1)
        do {
            let result = try await client.executeSql(session: session, request)
            if let transactionId = result.metadata?.transactionId {
                try? await client.rollback(session: session, transactionId: transactionId)
            }
            await sessions.releaseWriteSession(session)
            return result.stats?.queryPlan
        } catch let error as SpannerAPIError where error.isSessionNotFound {
            await sessions.discardWriteSession(session)
            throw error
        } catch {
            await sessions.releaseWriteSession(session)
            throw error
        }
    }
}
