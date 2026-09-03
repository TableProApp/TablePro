//
//  GroupPopUpButton.swift
//  TablePro
//

import AppKit
import SwiftUI

/// One row of a group pop-up menu. `indentationLevel` is the menu's own way of showing nesting,
/// which a run of leading spaces is not: spaces are read aloud by VoiceOver and lay out on the
/// wrong side in a right-to-left language.
internal struct GroupMenuEntry: Equatable, Identifiable {
    internal let id: UUID?
    internal let title: String
    internal let indentationLevel: Int
    internal let color: ConnectionColor
    internal let isEnabled: Bool
    internal let hasSeparatorAbove: Bool

    internal init(
        id: UUID?,
        title: String,
        indentationLevel: Int = 0,
        color: ConnectionColor = .none,
        isEnabled: Bool = true,
        hasSeparatorAbove: Bool = false
    ) {
        self.id = id
        self.title = title
        self.indentationLevel = indentationLevel
        self.color = color
        self.isEnabled = isEnabled
        self.hasSeparatorAbove = hasSeparatorAbove
    }
}

internal enum GroupMenuEntries {
    private static let maximumDepth = ConnectionGroup.maxNestingDepth

    internal static func forConnection(groups: [ConnectionGroup], noneTitle: String) -> [GroupMenuEntry] {
        var entries = [GroupMenuEntry(id: nil, title: noneTitle)]
        entries += flattenGroupsForMenu(groups: groups).enumerated().map { index, entry in
            GroupMenuEntry(
                id: entry.group.id,
                title: entry.group.name,
                indentationLevel: entry.depth,
                color: entry.group.color,
                hasSeparatorAbove: index == 0
            )
        }
        return entries
    }

    internal static func forParent(groups: [ConnectionGroup], noneTitle: String) -> [GroupMenuEntry] {
        var entries = [GroupMenuEntry(id: nil, title: noneTitle)]
        entries += flattenGroupsForMenu(groups: groups).enumerated().map { index, entry in
            GroupMenuEntry(
                id: entry.group.id,
                title: entry.group.name,
                indentationLevel: entry.depth,
                color: entry.group.color,
                isEnabled: depthOf(groupId: entry.group.id, groups: groups) < maximumDepth,
                hasSeparatorAbove: index == 0
            )
        }
        return entries
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
            if !entry.color.isDefault {
                item.image = colorDot(entry.color.color)
            }
            menu.addItem(item)
        }
        return menu
    }

    private static func colorDot(_ color: Color) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
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
