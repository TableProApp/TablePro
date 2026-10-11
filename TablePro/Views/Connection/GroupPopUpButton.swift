//
//  GroupPopUpButton.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProConnectionLibrary

/// One row of a group pop-up menu. `indentationLevel` is the menu's own way of showing nesting,
/// which a run of leading spaces is not: spaces are read aloud by VoiceOver and lay out on the
/// wrong side in a right-to-left language.
internal struct GroupMenuEntry: Equatable, Identifiable {
    internal let id: UUID?
    internal let title: String
    internal let indentationLevel: Int
    internal let color: ConnectionColor
    internal let iconName: String?
    internal let isEnabled: Bool
    internal let hasSeparatorAbove: Bool

    internal init(
        id: UUID?,
        title: String,
        indentationLevel: Int = 0,
        color: ConnectionColor = .none,
        iconName: String? = nil,
        isEnabled: Bool = true,
        hasSeparatorAbove: Bool = false
    ) {
        self.id = id
        self.title = title
        self.indentationLevel = indentationLevel
        self.color = color
        self.iconName = iconName
        self.isEnabled = isEnabled
        self.hasSeparatorAbove = hasSeparatorAbove
    }
}

internal enum GroupMenuEntries {
    internal static func forConnection(groups: [ConnectionGroup], noneTitle: String) -> [GroupMenuEntry] {
        entries(graph: LibraryGroupGraph(groups: groups), groups: groups, noneTitle: noneTitle, isEnabled: { _ in true })
    }

    internal static func forParent(groups: [ConnectionGroup], noneTitle: String) -> [GroupMenuEntry] {
        let graph = LibraryGroupGraph(groups: groups)
        return entries(graph: graph, groups: groups, noneTitle: noneTitle, isEnabled: { graph.canCreateSubgroup(under: $0) })
    }

    /// The parents an existing group can move under. Its own subtree is left out, because a group
    /// cannot sit inside itself, and a parent that would push the subtree past the nesting cap is
    /// shown dimmed, as one at the cap is when creating a group.
    internal static func forMoving(groupId: UUID, groups: [ConnectionGroup], noneTitle: String) -> [GroupMenuEntry] {
        let graph = LibraryGroupGraph(groups: groups)
        let subtree = graph.descendantIds(of: groupId).union([groupId])
        return entries(
            graph: graph,
            groups: groups,
            noneTitle: noneTitle,
            isOffered: { !subtree.contains($0) },
            isEnabled: { graph.canPlace(groupId, under: $0) }
        )
    }

    private static func entries(
        graph: LibraryGroupGraph,
        groups: [ConnectionGroup],
        noneTitle: String,
        isOffered: (UUID) -> Bool = { _ in true },
        isEnabled: (UUID) -> Bool
    ) -> [GroupMenuEntry] {
        let groupsById = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let offered: [(group: ConnectionGroup, depth: Int)] = graph.flattened().compactMap { flat in
            guard let group = groupsById[flat.id], isOffered(group.id) else { return nil }
            return (group, flat.depth)
        }
        var result = [GroupMenuEntry(id: nil, title: noneTitle)]
        for (index, (group, depth)) in offered.enumerated() {
            result.append(GroupMenuEntry(
                id: group.id,
                title: group.name,
                indentationLevel: depth,
                color: group.color,
                iconName: group.iconName,
                isEnabled: isEnabled(group.id),
                hasSeparatorAbove: index == 0
            ))
        }
        return result
    }
}

/// `NSPopUpButton` is the control macOS uses to pick one value from a menu. It carries the
/// selection, the checkmark, the menu role and the indentation for free; a SwiftUI `Picker` lowers
/// every option to a plain `NSMenuItem` and drops any layout the option carried.
internal struct GroupPopUpButton: NSViewRepresentable {
    internal let entries: [GroupMenuEntry]
    @Binding internal var selection: UUID?
    internal let accessibilityLabel: String

    internal func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    internal func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.setAccessibilityLabel(accessibilityLabel)
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return button
    }

    internal func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        guard context.coordinator.entries != entries else {
            context.coordinator.select(selection, in: button)
            return
        }
        context.coordinator.entries = entries
        button.menu = Self.makeMenu(entries: entries)
        context.coordinator.select(selection, in: button)
    }

    private static func makeMenu(entries: [GroupMenuEntry]) -> NSMenu {
        let menu = NSMenu()
        /// The pop up button owns the action, so its items carry none. Left on, automatic enabling
        /// would find no target for any of them and grey out the whole menu.
        menu.autoenablesItems = false
        for entry in entries {
            if entry.hasSeparatorAbove {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.indentationLevel = entry.indentationLevel
            item.isEnabled = entry.isEnabled
            item.representedObject = entry.id
            if entry.id != nil {
                item.setInformativeImage(LibraryGlyph.groupNSImage(iconName: entry.iconName, color: entry.color))
            }
            menu.addItem(item)
        }
        return menu
    }

    @MainActor
    internal final class Coordinator: NSObject {
        internal var entries: [GroupMenuEntry] = []
        internal var selection: Binding<UUID?>

        internal init(selection: Binding<UUID?>) {
            self.selection = selection
        }

        internal func select(_ id: UUID?, in button: NSPopUpButton) {
            let match = button.menu?.items.first { ($0.representedObject as? UUID) == id }
                ?? button.menu?.items.first { $0.representedObject == nil && !$0.isSeparatorItem }
            guard let match, button.selectedItem !== match else { return }
            button.select(match)
        }

        @objc internal func selectionChanged(_ sender: NSPopUpButton) {
            selection.wrappedValue = sender.selectedItem?.representedObject as? UUID
        }
    }
}
