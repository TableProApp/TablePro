//
//  MainContentCoordinator+Phase2Launch.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    // A tab can hold several: a page turned while the first page's definition read is still running starts another.
    struct Phase2Work {
        let token: UUID
        let tableName: String
        let resultSetId: UUID?
        let countsRows: Bool
        let task: Task<Void, Never>
        let schemaTask: Task<FetchedTableSchema, Error>?
    }

    func trackPhase2Work(_ work: Phase2Work, forTab tabId: UUID) {
        phase2Works[tabId, default: []].append(work)
    }

    func finishPhase2Work(_ token: UUID, forTab tabId: UUID) {
        phase2Works[tabId]?.removeAll { $0.token == token }
        if phase2Works[tabId]?.isEmpty == true { phase2Works[tabId] = nil }
    }

    // A page, sort or refresh of the same table keeps its read. So does a pinned result the tab keeps: nothing fetches its metadata later.
    func cancelPhase2Work(forTab tabId: UUID, unlessReading tableName: String? = nil, closingTab: Bool = false) {
        guard let works = phase2Works[tabId] else { return }
        let pinnedResults = closingTab
            ? []
            : tabManager.tabs.first { $0.id == tabId }?.display.resultSets.filter(\.isPinned).map(\.id) ?? []
        let kept = works.filter { work in
            if work.tableName == tableName { return true }
            if let resultSetId = work.resultSetId, pinnedResults.contains(resultSetId) { return true }
            work.schemaTask?.cancel()
            work.task.cancel()
            if work.countsRows { releaseCountPending(for: tabId) }
            return false
        }
        phase2Works[tabId] = kept.isEmpty ? nil : kept
    }

    func cancelAllPhase2Work() {
        for work in phase2Works.values.joined() {
            work.schemaTask?.cancel()
            work.task.cancel()
        }
        phase2Works.removeAll()
    }

    func launchPhase2AfterApply(
        tableName: String?,
        isEditable: Bool,
        tabId: UUID,
        trigger: TableLoadTrigger,
        needsMetadataFetch: Bool,
        schemaTask: Task<FetchedTableSchema, Error>?,
        claim: TabExecutionClaim,
        traceToken: TableLoadTraceToken? = nil
    ) {
        if isEditable, let tableName, trigger.countsRows {
            // Marked pending here: phase 1 clears `isLoading` first, so without it the tab looks settled and offers Count Exactly early.
            tabManager.mutate(tabId: tabId) { $0.pagination.isCountPending = true }
            launchPhase2(
                tableName: tableName,
                tabId: tabId,
                connectionType: connection.type,
                needsMetadataFetch: needsMetadataFetch,
                schemaTask: schemaTask,
                traceToken: traceToken
            )
        } else if isEditable, let tableName, needsMetadataFetch {
            // A tick keeps the count it has; only a manual Refresh recounts.
            launchPhase2Work(
                tableName: tableName,
                tabId: tabId,
                connectionType: connection.type,
                schemaTask: schemaTask,
                countsRows: false,
                traceToken: traceToken
            )
        } else if !isEditable || tableName == nil {
            clearChangesIfCurrent(claim: claim)
        }
    }
}
