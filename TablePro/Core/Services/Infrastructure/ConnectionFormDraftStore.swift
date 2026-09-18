//
//  ConnectionFormDraftStore.swift
//  TablePro
//

import Foundation

internal struct ConnectionFormDraft {
    internal let type: DatabaseType?
    internal let parsedURL: ParsedConnectionURL?

    internal init(type: DatabaseType? = nil, parsedURL: ParsedConnectionURL? = nil) {
        self.type = type
        self.parsedURL = parsedURL
    }
}

@MainActor
internal final class ConnectionFormDraftStore {
    internal static let shared = ConnectionFormDraftStore()

    private var drafts: [UUID: ConnectionFormDraft] = [:]

    private init() {}

    internal func stage(_ draft: ConnectionFormDraft) -> UUID {
        let draftId = UUID()
        drafts[draftId] = draft
        return draftId
    }

    internal func consume(_ draftId: UUID) -> ConnectionFormDraft? {
        defer { drafts[draftId] = nil }
        return drafts[draftId]
    }
}
