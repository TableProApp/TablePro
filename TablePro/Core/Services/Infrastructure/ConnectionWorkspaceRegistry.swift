//
//  ConnectionWorkspaceRegistry.swift
//  TablePro
//

import Foundation
import os

/// The set of connections one window hosts, and which of them it is showing. A window used to
/// answer this with its own identity, which could only ever name one connection.
@MainActor
internal final class ConnectionWorkspaceRegistry {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionWorkspace")

    private var workspacesById: [UUID: ConnectionWorkspace] = [:]
    private(set) var order: [UUID] = []
    private(set) var selectedConnectionId: UUID?

    internal var onSelectionChange: ((UUID?) -> Void)?
    internal var onMembershipChange: (() -> Void)?

    internal init() {}

    internal var isEmpty: Bool { order.isEmpty }

    internal var count: Int { order.count }

    internal var connectionIds: [UUID] { order }

    internal var workspaces: [ConnectionWorkspace] {
        order.compactMap { workspacesById[$0] }
    }

    internal var selected: ConnectionWorkspace? {
        guard let selectedConnectionId else { return nil }
        return workspacesById[selectedConnectionId]
    }

    internal func workspace(for connectionId: UUID) -> ConnectionWorkspace? {
        workspacesById[connectionId]
    }

    internal func contains(_ connectionId: UUID) -> Bool {
        workspacesById[connectionId] != nil
    }

    @discardableResult
    internal func insert(_ workspace: ConnectionWorkspace, select: Bool = true) -> ConnectionWorkspace {
        if let existing = workspacesById[workspace.connectionId] {
            if select { self.select(existing.connectionId) }
            return existing
        }
        workspacesById[workspace.connectionId] = workspace
        order.append(workspace.connectionId)
        Self.logger.info(
            "insert connId=\(workspace.connectionId, privacy: .public) count=\(self.order.count, privacy: .public)"
        )
        onMembershipChange?()
        if select || selectedConnectionId == nil {
            self.select(workspace.connectionId)
        }
        return workspace
    }

    /// Returns the workspace so the caller can tear it down after the registry no longer
    /// references it. A late connection attempt that finds no entry must discard its work
    /// rather than resurrect one, which is why removal is the generation check.
    @discardableResult
    internal func remove(_ connectionId: UUID) -> ConnectionWorkspace? {
        guard let removed = workspacesById.removeValue(forKey: connectionId) else { return nil }
        let removedIndex = order.firstIndex(of: connectionId)
        order.removeAll { $0 == connectionId }
        Self.logger.info(
            "remove connId=\(connectionId, privacy: .public) count=\(self.order.count, privacy: .public)"
        )
        if selectedConnectionId == connectionId {
            selectedConnectionId = nil
            select(Self.neighbour(in: order, removedIndex: removedIndex))
        }
        onMembershipChange?()
        return removed
    }

    internal func select(_ connectionId: UUID?) {
        guard selectedConnectionId != connectionId else { return }
        if let connectionId, workspacesById[connectionId] == nil { return }
        selectedConnectionId = connectionId
        Self.logger.info(
            "select connId=\(connectionId?.uuidString ?? "none", privacy: .public)"
        )
        onSelectionChange?(connectionId)
    }

    internal func cycleSelection(offsetBy offset: Int) {
        guard let next = Self.cycled(in: order, from: selectedConnectionId, by: offset) else { return }
        select(next)
    }

    /// The row that takes the removed row's place, so closing a connection lands on its
    /// neighbour instead of dropping the window to an empty pane while others are still open.
    internal static func neighbour(in order: [UUID], removedIndex: Int?) -> UUID? {
        guard !order.isEmpty else { return nil }
        guard let removedIndex else { return order.first }
        return order.indices.contains(removedIndex) ? order[removedIndex] : order.last
    }

    internal static func cycled(in order: [UUID], from current: UUID?, by offset: Int) -> UUID? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else { return order.first }
        let count = order.count
        let next = ((index + offset) % count + count) % count
        return order[next]
    }
}
