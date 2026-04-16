//
//  TabContentContainerView.swift
//  TablePro
//
//  AppKit container that manages one NSHostingView per tab.
//  Tab switching toggles NSView.isHidden — only the active tab
//  is visible. Note: hidden NSHostingViews still run SwiftUI
//  observation tracking; isHidden only suppresses rendering.
//

import SwiftUI

/// NSViewRepresentable that manages tab content views in AppKit.
/// Only the active tab's NSHostingView is visible (isHidden = false).
/// Inactive tabs are hidden so SwiftUI suspends their rendering.
@MainActor
struct TabContentContainerView: NSViewRepresentable {
    let tabManager: QueryTabManager
    let tabIds: [UUID]
    let activeTabContentVersion: Int
    let contentBuilder: (QueryTab) -> AnyView

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        var hostingViews: [UUID: NSHostingView<AnyView>] = [:]
        var activeTabId: UUID?
        var builtVersions: [UUID: Int] = [:]
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        syncHostingViews(container: container, coordinator: context.coordinator)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let coordinator = context.coordinator
        syncHostingViews(container: container, coordinator: coordinator)

        // Toggle visibility
        let selectedId = tabManager.selectedTabId
        if coordinator.activeTabId != selectedId {
            if let oldId = coordinator.activeTabId {
                coordinator.hostingViews[oldId]?.isHidden = true
            }
            if let newId = selectedId {
                coordinator.hostingViews[newId]?.isHidden = false
            }
            coordinator.activeTabId = selectedId
        }

        // Refresh active tab's rootView when content version changed.
        // activeTabContentVersion includes both per-tab state (resultVersion, metadataVersion)
        // and shared manager state (filterStateManager.isVisible, history panel).
        if let activeId = selectedId,
           let tab = tabManager.tabs.first(where: { $0.id == activeId }),
           let hosting = coordinator.hostingViews[activeId]
        {
            let builtVersion = coordinator.builtVersions[activeId] ?? -1
            if builtVersion != activeTabContentVersion {
                hosting.rootView = contentBuilder(tab)
                coordinator.builtVersions[activeId] = activeTabContentVersion
            }
        }
    }

    private func syncHostingViews(container: NSView, coordinator: Coordinator) {
        let currentIds = Set(tabIds)

        for id in coordinator.hostingViews.keys where !currentIds.contains(id) {
            coordinator.hostingViews[id]?.removeFromSuperview()
            coordinator.hostingViews.removeValue(forKey: id)
            coordinator.builtVersions.removeValue(forKey: id)
        }

        for tab in tabManager.tabs where coordinator.hostingViews[tab.id] == nil {
            let hosting = NSHostingView(rootView: contentBuilder(tab))
            hosting.translatesAutoresizingMaskIntoConstraints = false
            hosting.isHidden = (tab.id != tabManager.selectedTabId)
            container.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: container.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            coordinator.hostingViews[tab.id] = hosting
            coordinator.builtVersions[tab.id] = activeTabContentVersion
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        for hosting in coordinator.hostingViews.values {
            hosting.removeFromSuperview()
        }
        coordinator.hostingViews.removeAll()
        coordinator.builtVersions.removeAll()
    }
}
