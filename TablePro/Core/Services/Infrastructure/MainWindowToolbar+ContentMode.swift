//
//  MainWindowToolbar+ContentMode.swift
//  TablePro
//

import AppKit

/// The control that switches what the window shows: the object browser and editor, or the
/// assistant. It says **Assistant**, never "Agent". `AIChatMode` already has an `.agent` case in
/// the composer meaning "which tools may run", and two controls both labelled Agent, meaning
/// different things, is a support ticket generator.
extension MainWindowToolbar {
    private static let contentModeSegments: [ConnectionWorkspaceContentMode] = [.browse, .assistant]

    /// One name per mode, read by the control, the overflow menu and the accessibility description
    /// of the image, so the three cannot drift apart.
    internal static func contentModeLabel(_ mode: ConnectionWorkspaceContentMode) -> String {
        switch mode {
        case .browse: return String(localized: "Browse")
        case .assistant: return String(localized: "Assistant")
        }
    }

    private static func contentModeSymbol(_ mode: ConnectionWorkspaceContentMode) -> String {
        switch mode {
        case .browse: return "tablecells"
        case .assistant: return "sparkles"
        }
    }

    /// `.selectOne` is what makes this a one-of-N segmented control, the same shape the sidebar
    /// toggle uses. Not navigational: `isNavigational` lets AppKit lift an item out of its declared
    /// slot and pin it to the leading edge of the content title area, which is where back, forward
    /// and the connection chip already are.
    internal static func makeContentModeGroup(target: AnyObject?, action: Selector) -> NSToolbarItemGroup {
        let labels = contentModeSegments.map(contentModeLabel)
        /// The label goes on the image too, not only in `labels`. An expanded group builds its own
        /// segmented control and takes each segment's accessibility name from the image's
        /// `accessibilityDescription`, so a nil one leaves VoiceOver reading the SF Symbol name:
        /// the window's sidebar toggle announces itself as "List" and "favorite" for exactly this
        /// reason.
        let images = contentModeSegments.compactMap {
            NSImage(systemSymbolName: contentModeSymbol($0), accessibilityDescription: contentModeLabel($0))
        }
        let group = NSToolbarItemGroup(
            itemIdentifier: contentMode,
            images: images,
            selectionMode: .selectOne,
            labels: labels,
            target: target,
            action: action
        )
        group.label = String(localized: "Mode")
        group.paletteLabel = group.label
        group.controlRepresentation = .expanded
        return group
    }

    /// Only the item actually going into the toolbar may claim `contentModeGroup`. A Customize
    /// Toolbar palette copy that took the slot would leave every later sync writing into a
    /// discarded group, which is the bug the sidebar toggle's own `claimsSlot` exists to prevent.
    internal func makeContentModeItem(claimsSlot: Bool) -> NSToolbarItem {
        let group = Self.makeContentModeGroup(target: self, action: #selector(contentModeSegmentChanged(_:)))
        group.menuFormRepresentation = makeContentModeMenuForm()
        bindMenuForm(action: #selector(contentModeSegmentChanged(_:)), to: Self.contentMode)
        guard claimsSlot else { return group }
        contentModeGroup = group
        syncContentModeSelection()
        return group
    }

    /// What the overflow menu offers when the window is too narrow to draw the control.
    ///
    /// Built explicitly rather than left to AppKit. A group's default menu form sends the group's
    /// action with the `NSMenuItem` as the sender, and the sender is the only thing carrying which
    /// segment was chosen, so an action that could read a selection off a group alone dropped every
    /// press made from the overflow menu: choosing Browse or Assistant there did nothing at all, at
    /// the ordinary window widths where the control lives in that menu. Each item carries its
    /// segment in `tag`, which is what makes both senders answerable.
    private func makeContentModeMenuForm() -> NSMenuItem {
        let root = NSMenuItem(title: String(localized: "Mode"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: root.title)
        for (index, mode) in Self.contentModeSegments.enumerated() {
            let item = NSMenuItem(
                title: Self.contentModeLabel(mode),
                action: #selector(contentModeSegmentChanged(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            submenu.addItem(item)
        }
        root.submenu = submenu
        return root
    }

    /// `@objc` does not type-check the sender, and this action is reachable from the overflow menu
    /// as well as from the control. The group reports its choice as `selectedIndex` and a menu item
    /// as its `tag`; both resolve to the same segment index.
    @objc fileprivate func contentModeSegmentChanged(_ sender: Any?) {
        let index: Int
        switch sender {
        case let group as NSToolbarItemGroup:
            index = group.selectedIndex
        case let menuItem as NSMenuItem:
            index = menuItem.tag
        default:
            return
        }
        guard Self.contentModeSegments.indices.contains(index) else { return }
        coordinator?.splitViewController?.setContentMode(Self.contentModeSegments[index])
    }

    /// Pushed from the split view controller when the mode or the connection on screen changes,
    /// rather than observed. A view-backed group's subitems are never sent `validate()`, so there
    /// is no validation pass to piggyback on.
    ///
    /// The overflow menu's tick is pushed by the same pass. A menu built once at toolbar
    /// construction would otherwise report whichever mode the window opened in for the rest of its
    /// life.
    internal func syncContentModeSelection() {
        guard let group = contentModeGroup, let coordinator else { return }
        let mode = coordinator.splitViewController?.contentMode ?? .browse
        let index = Self.contentModeSegments.firstIndex(of: mode) ?? 0
        group.selectedIndex = index
        for item in group.menuFormRepresentation?.submenu?.items ?? [] {
            item.state = item.tag == index ? .on : .off
        }
    }
}
