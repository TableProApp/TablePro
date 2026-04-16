//
//  EditorTabBarItem.swift
//  TablePro
//
//  Individual tab item for the editor tab bar.
//

import SwiftUI

struct EditorTabBarItem: View {
    let tab: QueryTab
    let isSelected: Bool
    var isActiveTabDirty: Bool = false
    let databaseType: DatabaseType
    var onSelect: () -> Void
    var onClose: () -> Void
    var onCloseOthers: () -> Void
    var onCloseTabsToRight: () -> Void
    var onCloseAll: () -> Void
    var onDuplicate: () -> Void
    var onRename: (String) -> Void
    var onTogglePin: () -> Void

    @State private var isEditing = false
    @State private var editingTitle = ""
    @State private var isHovering = false
    @FocusState private var isEditingFocused: Bool

    private var icon: String {
        switch tab.tabType {
        case .table:
            return "tablecells"
        case .query:
            return "chevron.left.forwardslash.chevron.right"
        case .createTable:
            return "plus.rectangle"
        case .erDiagram:
            return "chart.dots.scatter"
        case .serverDashboard:
            return "gauge.with.dots.needle.bottom.50percent"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if isEditing {
                TextField("", text: $editingTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                    .frame(minWidth: 40, maxWidth: 120)
                    .focused($isEditingFocused)
                    .onSubmit {
                        let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            onRename(trimmed)
                        }
                        isEditing = false
                    }
                    .onChange(of: isEditingFocused) { _, focused in
                        if !focused && isEditing {
                            let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                onRename(trimmed)
                            }
                            isEditing = false
                        }
                    }
            } else {
                Text(tab.title)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                    .italic(tab.isPreview)
                    .lineLimit(1)
            }

            if tab.isFileDirty || tab.pendingChanges.hasChanges || isActiveTabDirty {
                Circle()
                    .fill(Color.primary.opacity(0.5))
                    .frame(width: 6, height: 6)
            }

            // Pinned tabs: show pin icon, no close button
            // Unpinned tabs: show close button on hover/selected
            if tab.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
            } else if isHovering || isSelected {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 14, height: 14)
                .accessibilityLabel(String(localized: "Close tab"))
            } else {
                Color.clear
                    .frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: ThemeEngine.shared.activeTheme.cornerRadius.small)
                .fill(isSelected ? Color(nsColor: .selectedControlColor) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onSelect() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            if tab.tabType == .query {
                Button(String(localized: "Rename")) {
                    editingTitle = tab.title
                    isEditing = true
                    isEditingFocused = true
                }
                Divider()
            }
            Button(tab.isPinned ? String(localized: "Unpin Tab") : String(localized: "Pin Tab")) {
                onTogglePin()
            }
            Divider()
            if !tab.isPinned {
                Button(String(localized: "Close")) { onClose() }
            }
            Button(String(localized: "Close Others")) { onCloseOthers() }
            Button(String(localized: "Close Tabs to the Right")) { onCloseTabsToRight() }
            Divider()
            Button(String(localized: "Close All")) { onCloseAll() }
            Divider()
            Button(String(localized: "Duplicate")) { onDuplicate() }
        }
    }
}
