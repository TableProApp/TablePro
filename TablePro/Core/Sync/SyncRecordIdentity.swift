//
//  SyncRecordIdentity.swift
//  TablePro
//

import Foundation
import TableProSyncTransport

/// The local identifier behind a record the push sent, kept because a CloudKit record name is an
/// identity rather than an encoding of that identifier.
struct SyncRecordIdentity: Hashable, Sendable {
    let type: SyncRecordType
    let id: String
}
