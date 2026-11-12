//
//  QueryTabVersionRecorder.swift
//  TablePro
//

import Foundation

@MainActor
internal struct QueryTabVersionRecorder {
    let storage: QueryTabVersionStorage
    // The Query History pause means "record nothing I run on this Mac", and a tab's drafts are the same text.
    var isCapturePaused: @MainActor @Sendable () -> Bool

    static let live = QueryTabVersionRecorder(storage: .shared, isCapturePaused: { QueryHistoryCaptureStore.isPaused })

    // The text is read now, so a later edit cannot change what this version holds.
    @discardableResult
    func record(_ tab: QueryTab?, connectionId: UUID, reason: QueryTabVersionReason) -> Task<Bool, Never>? {
        guard let tab, tab.tabType == .query, !isCapturePaused() else { return nil }
        let text = tab.content.query
        guard QueryTabVersionStorage.isRecordable(text) else { return nil }
        let storage = storage
        let tabId = tab.id
        return Task {
            await storage.record(tabId: tabId, connectionId: connectionId, text: text, reason: reason)
        }
    }
}
