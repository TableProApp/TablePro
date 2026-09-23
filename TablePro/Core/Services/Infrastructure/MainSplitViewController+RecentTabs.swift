//
//  MainSplitViewController+RecentTabs.swift
//  TablePro
//

import AppKit

/// Control-Tab across every connection this window hosts. The order is derived from each
/// connection's own record of when its tabs were selected, so nothing here has to follow a tab
/// that closes, moves to another window or arrives from a restore.
internal extension MainSplitViewController {
    @objc func switchToRecentTab(_ sender: Any?) {
        switchRecentTab(.forward, sender: sender)
    }

    @objc func switchToLeastRecentTab(_ sender: Any?) {
        switchRecentTab(.backward, sender: sender)
    }

    /// Control-Tab is the chord AppKit gives window tabs, so where there is no editor tab to switch
    /// to it still switches the window's tabs rather than doing nothing.
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

    /// A tab other than the one on screen, which a connection with no tab open of its own can still
    /// switch to in another connection.
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

    /// Only a connection that is on and browsing contributes. A tab behind a connecting or failed
    /// pane, or behind Agent mode, is a tab the user could not see after switching to it.
    private var recentTabWorkspaces: [ConnectionWorkspace] {
        workspaces.workspaces.filter(showsTabs)
    }

    private func showsTabs(_ workspace: ConnectionWorkspace) -> Bool {
        workspace.sessionState != nil
            && workspace.phase == .connected
            && workspace.resolvedPane == .content
            && workspace.resolvedContentMode == .browse
    }

    /// Settles which connection's tabs count as seen: the one on screen, while the window is key and
    /// its tabs are showing, and no other. Decided here from the window's own state rather than
    /// cached per coordinator, because a window hosting several connections has exactly one answer
    /// and every connection has to hear it, including one that just left the screen.
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

    /// At most one connection per window, and none while the window is not key.
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

    /// A row names its connection only when the window hosts more than one, where two connections
    /// can hold tabs with the same title.
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
                let title = labels[tab.id]?.text ?? tab.title
                rows[reference] = RecentTabCandidate(
                    reference: reference,
                    title: title,
                    detail: Self.recentTabDetail(
                        container: Self.recentTabContainer(of: tab, title: title, target: target),
                        connectionName: connectionName
                    ),
                    symbolName: Self.recentTabSymbol(for: tab)
                )
            }
        }

        return RecentTabOrder.order(sources: recentTabSources(), current: currentRecentTab)
            .compactMap { rows[$0] }
    }

    /// The tab is selected in its own connection first and the connection brought on screen second.
    /// Bringing a connection on screen records its selected tab as used, so the other order would
    /// record the tab it happened to be showing as the one the user came from.
    private func showRecentTab(_ reference: RecentTabReference) {
        guard hostsOpenTab(reference),
              let manager = workspaces.workspace(for: reference.connectionId)?.sessionState?.tabManager
        else { return }
        manager.selectedTabId = reference.tabId
        workspaces.select(reference.connectionId)
    }

    private func hostsOpenTab(_ reference: RecentTabReference) -> Bool {
        guard let workspace = recentTabWorkspaces.first(where: { $0.connectionId == reference.connectionId }),
              let manager = workspace.sessionState?.tabManager else { return false }
        return manager.tabs.contains { $0.id == reference.tabId }
    }

    /// The database or schema a table tab reads, unless the title already carries it.
    private static func recentTabContainer(of tab: QueryTab, title: String, target: ContainerSwitchTarget?) -> String? {
        guard tab.tableContext.tableName != nil,
              let container = WorkspaceAnchoring.containerName(of: tab, target: target),
              !container.isEmpty, !title.hasPrefix("\(container).") else { return nil }
        return container
    }

    private static func recentTabDetail(container: String?, connectionName: String?) -> String {
        [container, connectionName].compactMap { $0 }.joined(separator: " \u{00B7} ")
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
            return "gauge.with.dots.needle.33percent"
        case .usersRoles:
            return "person.2"
        case .insights:
            return "chart.bar"
        case .objectSource:
            return "curlybraces.square"
        case .versionHistory:
            return "clock.arrow.circlepath"
        }
    }
}
