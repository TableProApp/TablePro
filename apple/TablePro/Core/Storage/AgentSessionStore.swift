//
//  AgentSessionStore.swift
//  TablePro
//

import Foundation

// Device-local: CloudKit has no record type for a transcript. Not an actor, so restore lands before a first window mints a second session.
internal struct AgentSessionStore: Sendable {
    private let file: JSONFileStore<[AgentSessionRecord]>

    internal init(directory: URL? = nil) {
        let root = directory ?? AppStorageEnvironment.shared.applicationSupportRoot
            .appendingPathComponent("TablePro", isDirectory: true)
        file = JSONFileStore(
            url: root.appendingPathComponent("AgentSessions.json"),
            coding: .prettyISO8601,
            writingOptions: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    internal func load() -> [AgentSessionRecord] {
        file.read().value ?? []
    }

    internal func save(_ records: [AgentSessionRecord]) {
        try? file.write(records)
    }
}
