//
//  EditorTabContainerViewController.swift
//  TablePro
//

import AppKit
import os
import SwiftUI

@MainActor
final class EditorTabContainerViewController: NSTabViewController {
    private static let logger = Logger(subsystem: "com.TablePro", category: "EditorTabContainer")

    private let coordinator: MainContentCoordinator
    private let connection: DatabaseConnection
    private let rightPanelState: RightPanelState
    private let tabManager: QueryTabManager

    private var childControllers: [UUID: NSViewController] = [:]

    init(
        coordinator: MainContentCoordinator,
        connection: DatabaseConnection,
        rightPanelState: RightPanelState,
        tabManager: QueryTabManager
    ) {
        self.coordinator = coordinator
        self.connection = connection
        self.rightPanelState = rightPanelState
        self.tabManager = tabManager
        super.init(nibName: nil, bundle: nil)
        tabStyle = .unspecified
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorTabContainerViewController does not support NSCoder init")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        syncToTabManager()
    }

    func syncToTabManager() {
        let desiredIdSet = Set(tabManager.tabs.map(\.id))

        for item in tabViewItems where itemId(item).map({ desiredIdSet.contains($0) }) != true {
            removeTabViewItem(item)
        }
        for removedId in childControllers.keys where !desiredIdSet.contains(removedId) {
            childControllers.removeValue(forKey: removedId)
        }

        var itemsById = Dictionary(uniqueKeysWithValues: tabViewItems.compactMap { item -> (UUID, NSTabViewItem)? in
            guard let id = itemId(item) else { return nil }
            return (id, item)
        })

        for (index, tab) in tabManager.tabs.enumerated() {
            let item: NSTabViewItem
            if let existing = itemsById[tab.id] {
                item = existing
            } else {
                item = NSTabViewItem(identifier: tab.id.uuidString)
                item.viewController = childController(for: tab)
                itemsById[tab.id] = item
            }
            let currentIndex = tabViewItems.firstIndex(of: item)
            if currentIndex != index {
                if currentIndex != nil {
                    removeTabViewItem(item)
                }
                insertTabViewItem(item, at: min(index, tabViewItems.count))
            }
        }

        if let selectedId = tabManager.selectedTabId {
            selectTab(id: selectedId)
        }
    }

    func selectTab(id: UUID) {
        guard let index = tabViewItems.firstIndex(where: { itemId($0) == id }) else { return }
        guard selectedTabViewItemIndex != index else { return }
        selectedTabViewItemIndex = index
    }

    private func childController(for tab: QueryTab) -> NSViewController {
        if let existing = childControllers[tab.id] {
            return existing
        }
        let controller = NSHostingController(rootView: EditorTabPlaceholderView(title: tab.title))
        childControllers[tab.id] = controller
        Self.logger.debug("Created child controller for tab \(tab.id, privacy: .public)")
        return controller
    }

    private func itemId(_ item: NSTabViewItem) -> UUID? {
        guard let identifier = item.identifier as? String else { return nil }
        return UUID(uuidString: identifier)
    }
}

private struct EditorTabPlaceholderView: View {
    let title: String

    var body: some View {
        Text(title)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
    }
}
