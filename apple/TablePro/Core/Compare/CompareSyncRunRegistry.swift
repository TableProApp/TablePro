//
//  CompareSyncRunRegistry.swift
//  TablePro
//

import Foundation

@MainActor
internal final class CompareSyncRunRegistry {
    internal static let shared = CompareSyncRunRegistry()

    private struct Entry {
        weak var session: CompareSyncSession?
        let windowId: UUID
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    internal init() {}

    internal func track(_ session: CompareSyncSession, windowId: UUID) {
        entries[ObjectIdentifier(session)] = Entry(session: session, windowId: windowId)
    }

    internal func windowId(of session: CompareSyncSession) -> UUID? {
        entries[ObjectIdentifier(session)]?.windowId
    }

    internal func runningWork() -> [RunningWork] {
        entries = entries.filter { $0.value.session != nil }
        return entries.values.compactMap { entry in
            guard let session = entry.session else { return nil }
            return Self.runningWork(for: session)
        }
    }

    internal static func runningWork(for session: CompareSyncSession) -> RunningWork? {
        guard session.isBusy else { return nil }
        let endpoints = [session.source, session.target].compactMap { $0 }
        let kind: RunningWorkKind = session.activity == .applying ? .compareApply : .compareRun
        // A comparison reads "source with target"; an apply names only the target it writes to.
        let target = session.target?.qualifiedDescription ?? ""
        return RunningWork(
            id: session.workId,
            kind: kind,
            subject: kind == .compareApply ? target : session.source?.qualifiedDescription ?? "",
            connectionName: kind == .compareApply ? "" : target,
            connectionIds: Set(endpoints.map(\.scope.connectionId)),
            cancel: { [weak session] in session?.stopRunningWork() }
        )
    }
}
