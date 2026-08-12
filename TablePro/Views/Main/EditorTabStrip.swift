//
//  EditorTabStrip.swift
//  TablePro
//

import SwiftUI

/// The editor tabs for one connection. Native window tabs cannot express this: a window belongs
/// to exactly one tab group and a group's bar shows every window in it, so one window hosting
/// several connections could only ever show all of their tabs interleaved.
internal struct EditorTabStrip: View {
    internal let tabManager: QueryTabManager
    internal let onClose: (UUID) -> Void
    internal let onNewTab: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    internal var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabManager.tabs) { tab in
                        EditorTabStripItem(
                            tab: tab,
                            isSelected: tabManager.selectedTab?.id == tab.id,
                            onSelect: { tabManager.selectedTabId = tab.id },
                            onClose: { onClose(tab.id) }
                        )
                        Divider().frame(height: Self.dividerHeight)
                    }
                }
            }

            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .frame(width: Self.newTabButtonWidth, height: Self.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("New Tab"))
            .accessibilityLabel(Text("New Tab"))
        }
        .frame(height: Self.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Editor Tabs"))
    }

    internal static let height: CGFloat = 28
    private static let dividerHeight: CGFloat = 16
    private static let newTabButtonWidth: CGFloat = 28
}

private struct EditorTabStripItem: View {
    let tab: QueryTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(tab.title)
                .lineLimit(1)
                .italic(tab.isPreview)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 1 : 0)
            .accessibilityLabel(Text("Close Tab"))
        }
        .padding(.horizontal, 10)
        .frame(height: EditorTabStrip.height)
        .frame(minWidth: 80, maxWidth: 200)
        .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
        .help(Text(tab.title))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(tab.title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("Close Tab"), onClose)
    }
}
