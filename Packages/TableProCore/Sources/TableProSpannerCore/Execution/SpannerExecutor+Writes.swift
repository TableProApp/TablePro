import Foundation

extension SpannerExecutor {
    func executeDML(_ statement: SpannerPreparedStatement) async throws -> SpannerQueryOutcome {
        if await transactions.isIdle {
            return try await autocommitDML(statement)
        }
        return try await transactions.queue.run {
            switch try await self.transactions.claim() {
            case .idle:
                return try await self.autocommitDML(statement)
            case .open(let context):
                return try await self.dmlInTransaction(statement, context: context)
            }
        }
    }

    func executeRequest(
        _ statement: SpannerPreparedStatement,
        types: [SpannerType],
        transaction: SpannerTransactionSelector,
        seqno: Int64?
    ) throws -> SpannerExecuteSqlRequest {
        var params: [String: SpannerJSONValue] = [:]
        var paramTypes: [String: SpannerType] = [:]
        for (offset, value) in statement.parameters.enumerated() {
            let name = "p\(offset + 1)"
            guard types.indices.contains(offset) else { throw SpannerTransportError.invalidResponse }
            do {
                params[name] = try SpannerParameterEncoder.encode(value, as: types[offset], index: offset + 1)
            } catch let error as SpannerParameterEncodingError {
                throw SpannerExecutionError.parameterEncoding(error)
            }
            paramTypes[name] = types[offset]
        }
        return SpannerExecuteSqlRequest(
            sql: statement.sql,
            transaction: transaction,
            params: params,
            paramTypes: paramTypes,
            seqno: seqno
        )
    }

    private func dmlInTransaction(
        _ statement: SpannerPreparedStatement,
        context: SpannerTransactionContext
    ) async throws -> SpannerQueryOutcome {
        do {
            let types = try await dmlTypesInTransaction(statement, context: context)
            let seqno = try await transactions.nextSeqno(for: context)
            let request = try executeRequest(statement, types: types, transaction: .id(context.transactionId), seqno: seqno)
            let result = try await client.executeSql(session: context.session, request)
            return .resultSet(result, kind: .dml)
        } catch let error as SpannerAPIError {
            if error.isAborted || error.isSessionNotFound {
                await transactions.markAborted(context)
            } else if error.isInvalidArgument {
                await typeCache.evict(statement.sql)
            }
            throw error
        } catch {
            if SpannerTransactionController.outcomeIsUnknown(after: error) {
                await transactions.markAborted(context)
            }
            throw error
        }
    }

    private func dmlTypesInTransaction(
        _ statement: SpannerPreparedStatement,
        context: SpannerTransactionContext
    ) async throws -> [SpannerType] {
        if let declared = statement.declaredTypes {
            return declared
        }
        if let cached = await typeCache.types(for: statement.sql) {
            return cached
        }
        let seqno = try await transactions.nextSeqno(for: context)
        let request = SpannerExecuteSqlRequest(
            sql: statement.sql,
            transaction: .id(context.transactionId),
            queryMode: .plan,
            seqno: seqno
        )
        let plan = try await client.executeSql(session: context.session, request)
        let types = try SpannerParameterTypeCache.orderedTypes(
            from: plan.metadata?.undeclaredParameters ?? [],
            count: statement.parameters.count
        )
        await typeCache.store(types, for: statement.sql)
        return types
    }

    private func autocommitDML(_ statement: SpannerPreparedStatement) async throws -> SpannerQueryOutcome {
        var abortedAttempts = 0
        var rediscovered = false
        while true {
            do {
                return try await autocommitAttempt(statement, allowingLostSession: true)
            } catch let error as SpannerAPIError where error.isAborted && abortedAttempts < abortedRetryDelays.count {
                try await Task.sleep(for: abortedRetryDelays[abortedAttempts])
                abortedAttempts += 1
            } catch let error as SpannerAPIError where error.isInvalidArgument && !rediscovered && statement.needsTypeDiscovery {
                guard await typeCache.types(for: statement.sql) != nil else { throw error }
                await typeCache.evict(statement.sql)
                rediscovered = true
            }
        }
    }

    private func autocommitAttempt(
        _ statement: SpannerPreparedStatement,
        allowingLostSession: Bool
    ) async throws -> SpannerQueryOutcome {
        let session = try await sessions.leaseWriteSession()
        var progress = SpannerAutocommitProgress()
        do {
            let result = try await runAutocommit(statement, session: session, progress: &progress)
            await sessions.releaseWriteSession(session)
            return result
        } catch let error as SpannerAPIError where error.isSessionNotFound {
            await sessions.discardWriteSession(session)
            guard allowingLostSession, !progress.statementApplied else { throw error }
            return try await autocommitAttempt(statement, allowingLostSession: false)
        } catch {
            if let transactionId = progress.transactionId, !progress.commitSent {
                try? await client.rollback(session: session, transactionId: transactionId)
            }
            await sessions.releaseWriteSession(session)
            throw error
        }
    }

    private func runAutocommit(
        _ statement: SpannerPreparedStatement,
        session: String,
        progress: inout SpannerAutocommitProgress
    ) async throws -> SpannerQueryOutcome {
        var types = statement.declaredTypes
        if types == nil {
            types = await typeCache.types(for: statement.sql)
        }
        if types == nil {
            let plan = try await client.executeSql(
                session: session,
                SpannerExecuteSqlRequest(sql: statement.sql, transaction: .beginReadWrite, queryMode: .plan, seqno: 1)
            )
            progress.transactionId = plan.metadata?.transactionId
            progress.lastSeqno = 1
            let discovered = try SpannerParameterTypeCache.orderedTypes(
                from: plan.metadata?.undeclaredParameters ?? [],
                count: statement.parameters.count
            )
            await typeCache.store(discovered, for: statement.sql)
            types = discovered
        }
        let selector: SpannerTransactionSelector = progress.transactionId.map { .id($0) } ?? .beginReadWrite
        let request = try executeRequest(statement, types: types ?? [], transaction: selector, seqno: progress.lastSeqno + 1)
        let result = try await client.executeSql(session: session, request)
        progress.statementApplied = true
        guard let transactionId = progress.transactionId ?? result.metadata?.transactionId else {
            throw SpannerTransportError.invalidResponse
        }
        progress.transactionId = transactionId
        progress.commitSent = true
        let client = self.client
        do {
            try await Task { try await client.commit(session: session, transactionId: transactionId) }.value
        } catch {
            guard SpannerTransactionController.outcomeIsUnknown(after: error) else { throw error }
            throw SpannerExecutionError.commitOutcomeUnknown
        }
        return .resultSet(result, kind: .dml)
    }
}

internal struct SpannerAutocommitProgress: Sendable {
    var transactionId: String?
    var lastSeqno: Int64 = 0
    var statementApplied = false
    var commitSent = false
}
