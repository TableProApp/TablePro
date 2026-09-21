//
//  MenuValidationCoverageTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
private func flatten(_ menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { item -> [NSMenuItem] in
        guard let submenu = item.submenu, submenu !== NSApp.servicesMenu else { return [item] }
        return [item] + flatten(submenu)
    }
}

/// The selectors `validateMenuItem(_:)` answers itself, before the shared predicate runs. They read
/// live window state that no captured context carries, so they are decided but not through an arm.
/// Anything else the window implements has to have one, which is what the suite below holds.
@MainActor
private let liveValidatedSelectors: Set<Selector> = [
    #selector(NSSplitViewController.toggleSidebar(_:)),
    #selector(MainSplitViewController.toggleInspector(_:)),
    #selector(MainSplitViewController.toggleAssistant(_:)),
    #selector(MainSplitViewController.setResultView(_:)),
    #selector(MainSplitViewController.setSafeModeLevel(_:)),
    #selector(MainSplitViewController.setContentModeFromMenu(_:)),
    #selector(MainSplitViewController.toggleContentModeFromMenu(_:)),
    #selector(MainSplitViewController.requestDisconnect),
    #selector(MainSplitViewController.retryConnection),
]

@Suite("Menu validation coverage")
@MainActor
struct MenuValidationCoverageTests {
    /// A command the window implements and the menu carries, with no arm in `resolvedEnablement`,
    /// falls through to enabled and stays lit over a window that cannot run it. Nothing else says
    /// so: the compiler is satisfied, and every other menu test passes. That is how Clear Selection
    /// shipped enabled on a window with nothing selected.
    @Test("Every command the window owns is decided rather than left enabled by default")
    func everyOwnedSelectorIsDecided() {
        let context = MenuValidationContext()
        let undecided = flatten(MainMenuBuilder.build(keyboard: KeyboardSettings()))
            .filter { !$0.isSeparatorItem && $0.submenu == nil }
            .compactMap(\.action)
            .filter { MainSplitViewController.instancesRespond(to: $0) }
            .filter { !liveValidatedSelectors.contains($0) }
            .filter { MainSplitViewController.resolvedEnablement($0, context: context) == nil }
            .map(NSStringFromSelector)

        #expect(
            undecided.isEmpty,
            "No arm in resolvedEnablement, so these stay enabled on a window that cannot run them: \(undecided)"
        )
    }

    @Test("Clear Selection needs a connection rather than merely a window")
    func clearSelectionNeedsAConnection() {
        let selector = #selector(MainSplitViewController.clearSelection(_:))
        #expect(MainSplitViewController.resolvedEnablement(selector, context: MenuValidationContext()) == false)

        var context = MenuValidationContext()
        context.isConnected = true
        #expect(MainSplitViewController.resolvedEnablement(selector, context: context) == true)
    }

    /// A command that would focus nothing is dimmed rather than silently doing nothing, which is the
    /// trap a focus command falls into: `makeFirstResponder` accepts a view that cannot take the
    /// keyboard and reports success.
    @Test("Each Focus command follows its own pane's readiness")
    func focusCommandsFollowTheirPane() {
        let commands: [(selector: Selector, keyPath: WritableKeyPath<MenuValidationContext, Bool>)] = [
            (#selector(MainSplitViewController.focusObjectList(_:)), \.canFocusObjectList),
            (#selector(MainSplitViewController.focusEditor(_:)), \.canFocusEditor),
            (#selector(MainSplitViewController.focusResults(_:)), \.canFocusResults),
            (#selector(MainSplitViewController.focusInspector(_:)), \.canFocusInspector),
            (#selector(MainSplitViewController.focusAssistant(_:)), \.canFocusAssistant),
        ]

        for command in commands {
            let name = NSStringFromSelector(command.selector)
            var context = MenuValidationContext()
            #expect(MainSplitViewController.resolvedEnablement(command.selector, context: context) == false, "\(name)")

            context[keyPath: command.keyPath] = true
            #expect(MainSplitViewController.resolvedEnablement(command.selector, context: context) == true, "\(name)")
        }
    }

    /// The toolbar's Actions pull-down carries no target, so each entry reaches the window's
    /// controller through the responder chain and is validated there, the way the menu bar's own
    /// commands are. An entry the controller does not implement reaches nothing and AppKit draws it
    /// disabled, and one it implements with no arm stays lit over a window that cannot run it.
    /// Every context the resolver can be asked about is walked, and so are the leaves its two
    /// submenus fill when they open. A submenu's own row carries no selector, so it adds none.
    @Test("Every Actions entry reaches the window and is decided there")
    func everyActionsEntryIsAnsweredAndDecided() {
        let tabKinds: [TabType?] = [
            .query, .table, .createTable, .erDiagram, .serverDashboard, .usersRoles, .insights, .objectSource, nil,
        ]
        var selectors: Set<Selector> = [ImportFormatMenuDelegate.action, ContentModeMenuDelegate.action]
        for tabKind in tabKinds {
            for contentMode in ConnectionWorkspaceContentMode.allCases {
                for isConnected in [true, false] {
                    let context = ToolbarContext(
                        tabKind: tabKind,
                        resultsMode: .data,
                        contentMode: contentMode,
                        pane: isConnected ? .content : .unavailable(.notConnected),
                        isConnected: isConnected,
                        hasSelectedWorkspace: true,
                        supportsImport: true,
                        supportsServerDashboard: true,
                        isAIEnabled: true
                    )
                    for section in ConnectionActionsMenuResolver.sections(context) {
                        selectors.formUnion(section.entries.compactMap(\.selector))
                    }
                }
            }
        }

        let unanswered = selectors
            .filter { !MainSplitViewController.instancesRespond(to: $0) }
            .map(NSStringFromSelector)
        let undecided = selectors
            .filter { !liveValidatedSelectors.contains($0) }
            .filter { MainSplitViewController.resolvedEnablement($0, context: MenuValidationContext()) == nil }
            .map(NSStringFromSelector)

        #expect(selectors.count > 20, "Only \(selectors.count) selectors collected; the walk missed contexts")
        #expect(unanswered.isEmpty, "The window does not implement these, so AppKit draws them dead: \(unanswered)")
        #expect(undecided.isEmpty, "No arm in resolvedEnablement, so these stay lit: \(undecided)")
    }

    /// The fall-through still has to stand for everything the window does not own, or the system's
    /// own items would arrive disabled.
    @Test("A command the window does not own is left alone")
    func foreignSelectorsFallThrough() {
        let selector = #selector(NSWindow.performClose(_:))
        #expect(MainSplitViewController.resolvedEnablement(selector, context: MenuValidationContext()) == nil)
        #expect(MainSplitViewController.isEnabled(selector, context: MenuValidationContext()))
    }
}
