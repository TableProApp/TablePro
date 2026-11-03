//
//  RunningWork.swift
//  TablePro
//

import Foundation

internal enum RunningWorkKind: Sendable, Hashable {
    case query
    case restore
    case dataImport
    case dataExport
    case backup
    case tableTransfer
    case objectCopy
    case agentReply
    case compareRun
    case compareApply
}

internal struct RunningWork: Identifiable {
    internal let id: UUID
    internal let kind: RunningWorkKind
    internal let subject: String
    internal let connectionName: String
    internal let connectionIds: Set<UUID>
    // Only a query sets these: it belongs to one tab in one window.
    internal let windowId: UUID?
    internal let tabId: UUID?
    internal let cancel: @MainActor () -> Void

    internal init(
        id: UUID = UUID(),
        kind: RunningWorkKind,
        subject: String,
        connectionName: String,
        connectionIds: Set<UUID>,
        windowId: UUID? = nil,
        tabId: UUID? = nil,
        cancel: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.kind = kind
        self.subject = subject
        self.connectionName = connectionName
        self.connectionIds = connectionIds
        self.windowId = windowId
        self.tabId = tabId
        self.cancel = cancel
    }
}

internal enum RunningWorkScope: Equatable {
    case app
    case connection(UUID)
    case window(ids: Set<UUID>, connectionIds: Set<UUID>)
    case tabs(Set<UUID>)
    case items(Set<UUID>)

    internal func contains(_ work: RunningWork) -> Bool {
        switch self {
        case .app:
            return true
        case .connection(let connectionId):
            return work.connectionIds.contains(connectionId)
        case .window(let windowIds, let connectionIds):
            if let workWindow = work.windowId { return windowIds.contains(workWindow) }
            return !work.connectionIds.isDisjoint(with: connectionIds)
        case .tabs(let tabIds):
            return work.tabId.map(tabIds.contains) ?? false
        case .items(let ids):
            return ids.contains(work.id)
        }
    }
}

@MainActor
internal final class RunningWorkRegistry {
    internal static let shared = RunningWorkRegistry()

    private var registered: [UUID: RunningWork] = [:]
    private var order: [UUID] = []
    private let providers: [@MainActor () -> [RunningWork]]

    internal init(providers: [@MainActor () -> [RunningWork]]? = nil) {
        self.providers = providers ?? RunningWorkProviders.live
    }

    @discardableResult
    internal func begin(
        _ kind: RunningWorkKind,
        subject: String,
        connectionName: String,
        connectionIds: Set<UUID>,
        cancel: @escaping @MainActor () -> Void
    ) -> UUID {
        let work = RunningWork(
            kind: kind,
            subject: subject,
            connectionName: connectionName,
            connectionIds: connectionIds,
            cancel: cancel
        )
        registered[work.id] = work
        order.append(work.id)
        return work.id
    }

    internal func end(_ id: UUID?) {
        guard let id, registered.removeValue(forKey: id) != nil else { return }
        order.removeAll { $0 == id }
    }

    internal func items(in scope: RunningWorkScope) -> [RunningWork] {
        let pushed = order.compactMap { registered[$0] }
        let pulled = providers.flatMap { $0() }
        return (pushed + pulled).filter(scope.contains)
    }

    internal func cancel(_ items: [RunningWork]) {
        for work in items {
            work.cancel()
        }
    }
}
