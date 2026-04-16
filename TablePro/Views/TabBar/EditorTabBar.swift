//
//  EditorTabBar.swift
//  TablePro
//
//  Horizontal tab bar for switching between editor tabs within a connection window.
//  Replaces native macOS window tabs for instant tab switching.
//

import SwiftUI
import UniformTypeIdentifiers

struct EditorTabBar: View {
    let tabs: [QueryTab]
    @Binding var selectedTabId: UUID?
    let databaseType: DatabaseType
    var onClose: (UUID) -> Void
    var onCloseOthers: (UUID) -> Void
    var onCloseAll: () -> Void
    var onReorder: ([QueryTab]) -> Void
    var onRename: (UUID, String) -> Void
    var onAddTab: () -> Void
    var onDuplicate: (UUID) -> Void
    var onTogglePin: (UUID) -> Void

    @State private var draggedTabId: UUID?

    private var pinnedTabs: [QueryTab] { tabs.filter(\.isPinned) }
    private var unpinnedTabs: [QueryTab] { tabs.filter { !$0.isPinned } }

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 1) {
                        ForEach(pinnedTabs) { tab in
                            tabItem(for: tab)
                        }
                        if !pinnedTabs.isEmpty && !unpinnedTabs.isEmpty {
                            Divider()
                                .frame(height: 16)
                                .padding(.horizontal, 2)
                        }
                        ForEach(unpinnedTabs) { tab in
                            tabItem(for: tab)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: selectedTabId) { _, newId in
                    if let id = newId {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }

            Divider()
                .frame(height: 16)

            Button {
                onAddTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .help(String(localized: "New Tab"))
        }
        .frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func tabItem(for tab: QueryTab) -> some View {
        EditorTabBarItem(
            tab: tab,
            isSelected: tab.id == selectedTabId,
            databaseType: databaseType,
            onSelect: { selectedTabId = tab.id },
            onClose: { onClose(tab.id) },
            onCloseOthers: { onCloseOthers(tab.id) },
            onCloseTabsToRight: { closeTabsToRight(of: tab.id) },
            onCloseAll: onCloseAll,
            onDuplicate: { onDuplicate(tab.id) },
            onRename: { name in onRename(tab.id, name) },
            onTogglePin: { onTogglePin(tab.id) }
        )
        .id(tab.id)
        .onDrag {
            draggedTabId = tab.id
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(
            targetId: tab.id,
            tabs: tabs,
            draggedTabId: $draggedTabId,
            onReorder: onReorder
        ))
    }

    private func closeTabsToRight(of id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let idsToClose = tabs[(index + 1)...].filter { !$0.isPinned }.map(\.id)
        for tabId in idsToClose {
            onClose(tabId)
        }
    }
}

// MARK: - Drag & Drop

private struct TabDropDelegate: DropDelegate {
    let targetId: UUID
    let tabs: [QueryTab]
    @Binding var draggedTabId: UUID?
    let onReorder: ([QueryTab]) -> Void

    func performDrop(info: DropInfo) -> Bool {
        draggedTabId = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggedId = draggedTabId,
              draggedId != targetId,
              let fromIndex = tabs.firstIndex(where: { $0.id == draggedId }),
              let toIndex = tabs.firstIndex(where: { $0.id == targetId })
        else { return }

        var reordered = tabs
        let moved = reordered.remove(at: fromIndex)
        reordered.insert(moved, at: toIndex)
        onReorder(reordered)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        draggedTabId = nil
    }
}
