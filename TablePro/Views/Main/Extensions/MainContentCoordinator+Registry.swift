//
//  MainContentCoordinator+Registry.swift
//  TablePro
//

import AppKit
import Foundation
import os

extension MainContentCoordinator {
    static func allActiveCoordinators() -> [MainContentCoordinator] {
        Array(activeCoordinators.values)
    }

    static func coordinator(for windowId: UUID) -> MainContentCoordinator? {
        activeCoordinators.values.first { $0.windowId == windowId }
    }

    /// The coordinator the window is currently showing. Every connection the window hosts has a
    /// coordinator whose `contentWindow` is this window, so matching on that alone returned an
    /// arbitrary one of them and let Cmd+W, Cmd+T and menu validation act on a connection the
    /// user was not looking at.
    static func coordinator(forWindow window: NSWindow) -> MainContentCoordinator? {
        guard let host = window.contentViewController as? MainSplitViewController else {
            return activeCoordinators.values.first { $0.contentWindow === window }
        }
        return host.workspaces.selected?.sessionState?.coordinator
    }

    static func hasAnyUnsavedChanges() -> Bool {
        activeCoordinators.values.contains { $0.hasAnyUnsavedWork() }
    }

    /// Disconnecting ends the session behind every window on the connection, so what is at risk is
    /// never just the window the command came from. The rail and the connection list can both fire
    /// it for a connection whose windows are all in the background.
    static func hasUnsavedWork(forConnection connectionId: UUID) -> Bool {
        activeCoordinators.values
            .filter { $0.connectionId == connectionId }
            .contains { $0.hasAnyUnsavedWork() }
    }

    static func hasRunningQuery(forConnection connectionId: UUID) -> Bool {
        activeCoordinators.values
            .filter { $0.connectionId == connectionId }
            .contains { $0.tabExecution.isAnyExecuting }
    }

    /// The connection's tabs, taken from the coordinator its window hosts.
    ///
    /// `activeCoordinators` cannot answer this on its own. It is keyed by instance and also holds
    /// the throwaway coordinators SwiftUI builds and discards while re-evaluating a body, and those
    /// leave the registry only when they deallocate, so for a while two instances of one connection
    /// are listed and this returned both of their tab lists. A caller that only numbers a new tab
    /// survives that; the connections strip does not, because a discarded instance's stale copy of a
    /// closed tab kept its container listed and the entry would not go away.
    ///
    /// The registry is still the fallback, for the window that has not adopted its session yet.
    static func allTabs(for connectionId: UUID) -> [QueryTab] {
        if let hosted = WindowManager.shared.workspace(for: connectionId)?.sessionState?.coordinator {
            return hosted.tabManager.tabs
        }
        let registered = activeCoordinators.values.filter { $0.connectionId == connectionId }
        if registered.count > 1 {
            Logger(subsystem: "com.TablePro", category: "MainContentCoordinator").debug(
                """
                allTabs fell back to \(registered.count, privacy: .public) registered coordinators \
                conn=\(connectionId, privacy: .public)
                """
            )
        }
        return registered.flatMap { $0.tabManager.tabs }
    }

    static func coordinator(
        forConnection connectionId: UUID,
        tabMatching predicate: (QueryTab) -> Bool
    ) -> MainContentCoordinator? {
        activeCoordinators.values.first { coordinator in
            coordinator.connectionId == connectionId
                && coordinator.tabManager.tabs.contains(where: predicate)
        }
    }
}
