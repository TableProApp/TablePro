//
//  CompareSyncPayload.swift
//  TablePro
//
//  Scene payload for the Compare & Sync window. A dedicated type rather than a
//  bare UUID?, so this scene never competes with the connection form for an
//  openWindow(value:) call carrying the same payload type.
//

import Foundation

internal struct CompareSyncPayload: Codable, Hashable {
    internal let sourceConnectionId: UUID?

    internal init(sourceConnectionId: UUID? = nil) {
        self.sourceConnectionId = sourceConnectionId
    }
}
