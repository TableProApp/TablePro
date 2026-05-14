//
//  EditorTabStripView.swift
//  TablePro
//

import SwiftUI
import UniformTypeIdentifiers

struct EditorTabStripView: View {
    @Bindable var tabManager: QueryTabManager
    let onNewTab: () -> Void
    let onCloseTab: (UUID) -> Void
    let onSelectTab: (UUID) -> Void
    let onMoveTab: (IndexSet, Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabManager.tabs) { tab in
                        EditorTabItemView(
                            tab: tab,
                            isSelected: tab.id == tabManager.selectedTabId,
                            onSelect: { onSelectTab(tab.id) },
                            onClose: { onCloseTab(tab.id) }
                        )
                        .onDrag {
                            NSItemProvider(object: tab.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: EditorTabDropDelegate(
                                targetTabId: tab.id,
                                tabManager: tabManager,
                                onMoveTab: onMoveTab
                            )
                        )
                        Divider().frame(height: 16)
                    }
                }
            }

            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help(String(localized: "New Tab"))
        }
        .frame(height: 28)
        .background(.bar)
    }
}

private struct EditorTabItemView: View {
    let tab: QueryTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(tab.title)
                .font(.system(size: 12))
                .italic(tab.isPreview)
                .lineLimit(1)

            closeOrDirtyIndicator
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(minWidth: 100, maxWidth: 220)
        .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var closeOrDirtyIndicator: some View {
        if isHovering {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help(String(localized: "Close Tab"))
        } else if tab.content.isFileDirty {
            Circle()
                .fill(.secondary)
                .frame(width: 6, height: 6)
                .frame(width: 16, height: 16)
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }

    private var iconName: String {
        switch tab.tabType {
        case .query:
            return "doc.text"
        case .table:
            return "tablecells"
        case .createTable:
            return "plus.rectangle.on.folder"
        case .erDiagram:
            return "point.3.connected.trianglepath.dotted"
        case .serverDashboard:
            return "gauge.with.dots.needle.bottom.50percent"
        case .terminal:
            return "terminal"
        }
    }
}

private struct EditorTabDropDelegate: DropDelegate {
    let targetTabId: UUID
    let tabManager: QueryTabManager
    let onMoveTab: (IndexSet, Int) -> Void

    func performDrop(info: DropInfo) -> Bool {
        guard let item = info.itemProviders(for: [.text]).first else { return false }
        item.loadObject(ofClass: NSString.self) { object, _ in
            guard let uuidString = object as? String,
                  let draggedId = UUID(uuidString: uuidString)
            else { return }
            Task { @MainActor in
                guard let sourceIndex = tabManager.tabs.firstIndex(where: { $0.id == draggedId }),
                      let targetIndex = tabManager.tabs.firstIndex(where: { $0.id == targetTabId }),
                      sourceIndex != targetIndex
                else { return }
                let destination = targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
                onMoveTab(IndexSet(integer: sourceIndex), destination)
            }
        }
        return true
    }
}
