//
//  MainWindowToolbar+ContentMode.swift
//  TablePro
//

import AppKit

/// The Browse / Agent control, and the overflow menu it owns.
///
/// Two things this gets right that the sidebar control next to it had to be fixed for. Each segment
/// names itself through its image's `accessibilityDescription`, which is measured to be the only
/// channel an expanded group publishes a segment name on. And the overflow menu form is built here
/// rather than left to AppKit, with each item carrying its segment in `tag`, so choosing a mode from
/// the overflow acts. AppKit's own generated form forwards the group as the sender on macOS 27, but
/// that is undocumented; owning the form makes the OS version stop mattering.
internal extension MainWindowToolbar {
    static let contentModeItem = NSToolbarItem.Identifier("contentMode")

    static var contentModes: [ConnectionWorkspaceContentMode] {
        ConnectionWorkspaceContentMode.allCases
    }

    static func makeContentModeGroup(target: AnyObject?, action: Selector) -> NSToolbarItemGroup {
        let modes = contentModes
        let images = modes.compactMap {
            NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: $0.localizedTitle)
        }
        let group = NSToolbarItemGroup(
            itemIdentifier: contentModeItem,
            images: images,
            selectionMode: .selectOne,
            labels: modes.map(\.localizedTitle),
            target: target,
            action: action
        )
        group.label = String(localized: "Mode")
        group.paletteLabel = group.label
        group.controlRepresentation = .expanded
        /// Not navigational: that flag lets AppKit lift an item out of its declared slot and pin it
        /// to the leading edge, which is where the sidebar control ended up before it was cleared.
        group.isNavigational = false
        group.menuFormRepresentation = makeContentModeMenuForm(target: target, action: action)
        return group
    }

    /// A "Mode" root with one item per mode, each carrying its index in `tag`.
    static func makeContentModeMenuForm(target: AnyObject?, action: Selector) -> NSMenuItem {
        let root = NSMenuItem(title: String(localized: "Mode"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: root.title)
        for (index, mode) in contentModes.enumerated() {
            let item = NSMenuItem(title: mode.localizedTitle, action: action, keyEquivalent: "")
            item.target = target
            item.tag = index
            submenu.addItem(item)
        }
        root.submenu = submenu
        return root
    }

    func makeContentModeToolbarItem(claimsSlot: Bool) -> NSToolbarItem {
        let group = Self.makeContentModeGroup(target: self, action: #selector(contentModeChanged(_:)))
        bindMenuForm(action: #selector(contentModeChanged(_:)), to: Self.contentModeItem)
        guard claimsSlot else { return group }
        contentModeGroup = group
        refreshContentMode()
        return group
    }

    @objc func contentModeChanged(_ sender: Any?) {
        guard let index = Self.segmentIndex(from: sender, group: contentModeGroup),
              Self.contentModes.indices.contains(index) else { return }
        coordinator?.splitViewController?.setContentMode(Self.contentModes[index])
    }

    /// Pushed from the split view controller when the mode changes, and the tick in the overflow
    /// menu follows the same pass the segments do rather than being a second channel that can drift.
    func refreshContentMode() {
        guard let group = contentModeGroup else { return }
        let mode = coordinator?.splitViewController?.contentMode ?? .browse
        let index = Self.contentModes.firstIndex(of: mode) ?? 0
        group.selectedIndex = index
        for (itemIndex, item) in (group.menuFormRepresentation?.submenu?.items ?? []).enumerated() {
            item.state = itemIndex == index ? .on : .off
        }
        managedToolbar.validateVisibleItems()
    }
}
