//
//  SheetWork.swift
//  TablePro
//

import Foundation

// What a sheet's owner stops when it goes away for good. A pane leaving the window on a connection
// switch or an Agent mode toggle is not that, which is why this is not `onDisappear`.
@MainActor
internal final class SheetWorkScope {
    private var stops: [UUID: @MainActor () -> Void] = [:]
    private let windowIdProvider: @MainActor () -> UUID?

    internal init(windowId: @escaping @MainActor () -> UUID? = { nil }) {
        windowIdProvider = windowId
    }

    internal var windowId: UUID? { windowIdProvider() }

    internal var isEmpty: Bool { stops.isEmpty }

    internal func begin(stop: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        stops[id] = stop
        return id
    }

    internal func end(_ id: UUID?) {
        guard let id else { return }
        stops[id] = nil
    }

    internal func stopAll() {
        let pending = Array(stops.values)
        stops.removeAll()
        for stop in pending {
            stop()
        }
    }
}

// One job a sheet started: listed for the closers' running-work question and stopped with the sheet's owner.
@MainActor
internal final class SheetJob {
    private let registry: RunningWorkRegistry
    private weak var scope: SheetWorkScope?
    private let workId: UUID
    private let scopeId: UUID?

    internal init(
        _ kind: RunningWorkKind,
        subject: String,
        connectionName: String,
        connectionIds: Set<UUID>,
        registry: RunningWorkRegistry = .shared,
        scope: SheetWorkScope?,
        listedOnlyForItsWindow: Bool = true,
        stop: @escaping @MainActor () -> Void
    ) {
        self.registry = registry
        self.scope = scope
        workId = registry.begin(
            kind,
            subject: subject,
            connectionName: connectionName,
            connectionIds: connectionIds,
            windowId: listedOnlyForItsWindow ? scope?.windowId : nil,
            cancel: stop
        )
        scopeId = scope?.begin(stop: stop)
    }

    internal func end() {
        registry.end(workId)
        scope?.end(scopeId)
    }
}
