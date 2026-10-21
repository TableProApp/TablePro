//
//  OraclePluginDriver+Explain.swift
//  OracleDriverPlugin
//

import Foundation
import TableProOracleCore
import TableProPluginKit

extension OraclePluginDriver {
    func explainPlan(statement: String, variantId: String) async throws -> PluginQueryResult {
        guard let core else { throw OraclePluginError(core: .notConnected) }
        let startTime = Date()
        let rows: OracleRawResult
        do {
            switch variantId {
            case OracleExplainPlan.estimatedVariantId:
                rows = try await estimatedPlan(of: statement, on: core)
            case OracleExplainPlan.actualVariantId:
                rows = try await actualPlan(of: statement, on: core)
            default:
                throw PluginDriverUnsupportedOperation.explainPlan
            }
        } catch let error as OracleCoreError {
            throw error.asPluginError
        }
        guard !rows.rows.isEmpty else {
            throw OraclePluginError(core: .queryFailed(OracleExplainPlan.noPlanMessage))
        }
        return PluginQueryResult(
            columns: ["PLAN"],
            columnTypeNames: ["CLOB"],
            rows: [[.text(OracleExplainPlan.document(from: rows))]],
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func estimatedPlan(of statement: String, on core: OracleCoreConnection) async throws -> OracleRawResult {
        let statementId = OracleExplainPlan.statementId()
        _ = try await core.executeQuery(OracleExplainPlan.explainStatement(statement, statementId: statementId))
        let rows: OracleRawResult
        do {
            rows = try await core.executeQuery(OracleExplainPlan.planRowsQuery(statementId: statementId))
        } catch {
            _ = try? await core.executeQuery(OracleExplainPlan.deleteStatement(statementId: statementId))
            throw error
        }
        _ = try? await core.executeQuery(OracleExplainPlan.deleteStatement(statementId: statementId))
        return rows
    }

    private func actualPlan(of statement: String, on core: OracleCoreConnection) async throws -> OracleRawResult {
        let probe: OracleRawResult
        do {
            probe = try await core.executeQuery(OracleExplainPlan.actualPlanProbe)
        } catch let error where OracleExplainPlan.isMissingGrant(error) {
            throw OracleCoreError.queryFailed(OracleExplainPlan.missingGrantsMessage)
        }
        let sessionLevel = probe.rows.first?.first?.stringValue ?? ""
        let restore = OracleExplainPlan.setStatisticsLevel(sessionLevel)
        let gathers = sessionLevel.uppercased() == OracleExplainPlan.gatheringLevel
        if !gathers, let gather = OracleExplainPlan.setStatisticsLevel(OracleExplainPlan.gatheringLevel) {
            _ = try await core.executeQuery(gather)
        }
        let answer: Result<OracleRawResult, Error>
        do {
            answer = .success(
                try await core.executeDiscardingRows(
                    OracleExplainPlan.bare(statement),
                    thenQuery: OracleExplainPlan.lastCursorPlanQuery
                )
            )
        } catch {
            answer = .failure(error)
        }
        if !gathers, let restore {
            // Detached from the caller's cancellation, so a stopped statement still leaves the session as it was.
            _ = try? await Task { try await core.executeQuery(restore) }.value
        }
        return try answer.get()
    }
}
