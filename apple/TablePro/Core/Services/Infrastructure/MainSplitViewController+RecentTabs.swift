//
//  MainSplitViewController+RecentTabs.swift
//  TablePro
//

import AppKit

// Control-Tab across the window's connections, ordered from each one's selection record, so nothing here follows a
// tab that closes, moves or is restored.
internal extension MainSplitViewController {
    @objc func switchToRecentTab(_ sender: Any?) {
        switchRecentTab(.forward, sender: sender)
    }

    @objc func switchToLeastRecentTab(_ sender: Any?) {
        switchRecentTab(.backward, sender: sender)
    }

    // Control-Tab is AppKit's window-tab chord, so with no editor tab to switch to it still switches window tabs.
    private func switchRecentTab(_ direction: RecentTabSwitchDirection, sender: Any?) {
        guard canSwitchToRecentTab else {
            switch direction {
            case .forward:
                view.window?.selectNextTab(sender)
            case .backward:
                view.window?.selectPreviousTab(sender)
            }
            return
        }
        beginRecentTabSwitch(direction)
    }

    var canSwitchToRecentTab: Bool {
        isConnected && contentMode != .agent && hasRecentTabToSwitchTo
    }

    var hasOtherWindowTabs: Bool {
        (view.window?.tabbedWindows?.count ?? 0) > 1
    }

    // A connection with no tab of its own can still switch to another connection's.
    var hasRecentTabToSwitchTo: Bool {
        let tabCount = recentTabSources().reduce(0) { $0 + $1.tabIds.count }
        let showsOneOfThem = currentRecentTab.map(hostsOpenTab) ?? false
        return tabCount > (showsOneOfThem ? 1 : 0)
    }

    private func beginRecentTabSwitch(_ direction: RecentTabSwitchDirection) {
        quickSwitcherPanel.dismiss()
        let candidates = recentTabCandidates()
        recentTabSwitcher.begin(
            candidates: candidates,
            leadsWithCurrentTab: candidates.first.map { $0.reference == currentRecentTab } ?? false,
            direction: direction,
            trigger: NSApp.currentEvent,
            window: view.window,
            isOpen: { [weak self] reference in self?.hostsOpenTab(reference) ?? false },
            onCommit: { [weak self] reference in self?.showRecentTab(reference) }
        )
    }

    // A tab behind a connecting or failed pane, or behind Agent mode, could not be seen after switching to it.
    private var recentTabWorkspaces: [ConnectionWorkspace] {
        workspaces.workspaces.filter(showsTabs)
    }

    private func showsTabs(_ workspace: ConnectionWorkspace) -> Bool {
        workspace.sessionState != nil
            && workspace.phase == .connected
            && workspace.resolvedPane == .content
            && workspace.resolvedContentMode == .browse
    }

    // Decided from the window, not cached per coordinator: a window has one answer and every connection must hear it,
    // including one that just left the screen.
    func syncFrontmostTabManager() {
        let frontmost = Self.frontmostConnectionId(
            selectedConnectionId: workspaces.selectedConnectionId,
            windowIsKey: view.window?.isKeyWindow == true,
            showsTabs: { [weak self] connectionId in
                guard let self, let workspace = self.workspaces.workspace(for: connectionId) else { return false }
                return self.showsTabs(workspace)
            }
        )
        for workspace in workspaces.workspaces {
            workspace.sessionState?.tabManager.isFrontmost = workspace.connectionId == frontmost
        }
    }

    static func frontmostConnectionId(
        selectedConnectionId: UUID?,
        windowIsKey: Bool,
        showsTabs: (UUID) -> Bool
    ) -> UUID? {
        guard windowIsKey, let selectedConnectionId, showsTabs(selectedConnectionId) else { return nil }
        return selectedConnectionId
    }

    private func recentTabSources() -> [RecentTabSource] {
        recentTabWorkspaces.compactMap { workspace in
            guard let manager = workspace.sessionState?.tabManager else { return nil }
            return RecentTabSource(
                connectionId: workspace.connectionId,
                tabIds: manager.tabIds,
                activationSequence: manager.activationSequence
            )
        }
    }

    private var currentRecentTab: RecentTabReference? {
        guard let workspace = workspaces.selected,
              let tabId = workspace.sessionState?.tabManager.selectedTab?.id else { return nil }
        return RecentTabReference(connectionId: workspace.connectionId, tabId: tabId)
    }

    // Two connections can hold tabs with the same title, so a row names its connection once the window hosts several.
    func recentTabCandidates() -> [RecentTabCandidate] {
        let hosted = recentTabWorkspaces
        let namesConnection = hosted.count > 1
        var rows: [RecentTabReference: RecentTabCandidate] = [:]

        for workspace in hosted {
            guard let tabs = workspace.sessionState?.tabManager.tabs else { continue }
            let target = workspace.connection.flatMap { PluginManager.shared.containerSwitchTarget(for: $0.type) }
            let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: target)
            let connectionName = namesConnection ? workspace.connection?.name : nil
            for tab in tabs {
                let reference = RecentTabReference(connectionId: workspace.connectionId, tabId: tab.id)
                let label = labels[tab.id]
                rows[reference] = RecentTabCandidate(
                    reference: reference,
                    title: label?.text ?? tab.title,
                    detail: Self.recentTabDetail(container: label?.container, connectionName: connectionName),
                    symbolName: Self.recentTabSymbol(for: tab)
                )
            }
        }

        return RecentTabOrder.order(sources: recentTabSources(), current: currentRecentTab)
            .compactMap { rows[$0] }
    }

    // Tab before connection: bringing a connection on screen records its selected tab as used.
    private func showRecentTab(_ reference: RecentTabReference) {
        guard hostsOpenTab(reference),
              let sessionState = workspaces.workspace(for: reference.connectionId)?.sessionState
        else { return }
        let manager = sessionState.tabManager
        TabSwitchTracer.shared.requestSwitch(.recentTab, to: reference.tabId)
        let changesTab = manager.selectedTabId != reference.tabId
        let arriving = sessionState.coordinator.arrivingRows(for: reference.tabId)
        manager.selectedTabId = reference.tabId
        workspaces.select(reference.connectionId)
        // Only the connection changes, so no tab selection reaches handleTabChange.
        if !changesTab {
            TabSwitchTracer.shared.selectionApplied(
                tabId: reference.tabId,
                rows: arriving,
                window: view.window,
                isShowing: { [weak manager] in manager?.isShowing(reference.tabId) ?? false }
            )
        }
    }

    private func hostsOpenTab(_ reference: RecentTabReference) -> Bool {
        guard let workspace = recentTabWorkspaces.first(where: { $0.connectionId == reference.connectionId }),
              let manager = workspace.sessionState?.tabManager else { return false }
        return manager.tabs.contains { $0.id == reference.tabId }
    }

    private static func recentTabDetail(container: String?, connectionName: String?) -> String {
        [container, connectionName].compactMap { $0 }.joined(separator: ", ")
    }

    private static func recentTabSymbol(for tab: QueryTab) -> String {
        switch tab.tabType {
        case .query:
            return "doc.text"
        case .table:
            return tab.tableContext.isView ? "eye" : "tablecells"
        case .createTable:
            return "tablecells.badge.ellipsis"
        case .erDiagram:
            return "point.3.connected.trianglepath.dotted"
        case .serverDashboard:
            return "speedometer"
        case .usersRoles:
            return "person.2"
        case .insights:
            return "chart.bar"
        case .tableHealth:
            return "stethoscope"
        case .objectSource:
            return "curlybraces.square"
        case .versionHistory:
            return "clock.arrow.circlepath"
        case .tableListing:
            return "list.bullet.rectangle"
        case .routineDebug:
            return "ladybug"
        case .liveMessages:
            return "dot.radiowaves.left.and.right"
        }
    }
}
