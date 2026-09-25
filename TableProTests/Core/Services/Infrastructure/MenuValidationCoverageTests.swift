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

    /// The session commands reach the window from the rail today and from the menu bar next, and a
    /// selector with no arm here is enabled over a window that cannot run it. Each of them needs the
    /// rail on screen, and all but New Session need a session to act on.
    @Test("Each session command is decided by the mode and by the session it would act on")
    func sessionCommandsAreDecided() {
        let commands: [(selector: Selector, needsTarget: Bool)] = [
            (#selector(MainSplitViewController.newAgentSession(_:)), false),
            (#selector(MainSplitViewController.openAgentSession(_:)), true),
            (#selector(MainSplitViewController.closeAgentSession(_:)), true),
            (#selector(MainSplitViewController.deleteAgentSession(_:)), true),
        ]

        for command in commands {
            let name = NSStringFromSelector(command.selector)
            var browsing = MenuValidationContext()
            browsing.agentSessionTarget = .ready
            #expect(
                MainSplitViewController.resolvedEnablement(command.selector, context: browsing) == false,
                "\(name) is a command of the rail, which browsing does not draw"
            )

            var agent = MenuValidationContext()
            agent.isAgentMode = true
            #expect(
                MainSplitViewController.resolvedEnablement(command.selector, context: agent) == !command.needsTarget,
                "\(name) with no session highlighted"
            )

            agent.agentSessionTarget = .ready
            #expect(MainSplitViewController.resolvedEnablement(command.selector, context: agent) == true, "\(name)")
        }
    }

    /// Closing is the one that cares what the session is doing: a session that has already ended
    /// cannot be closed again, and a stopped one is still there to open or delete.
    @Test("Close Session dims over a session that has already ended")
    func closeSessionFollowsTheSessionsState() {
        var context = MenuValidationContext()
        context.isAgentMode = true
        context.agentSessionTarget = .stopped

        #expect(MainSplitViewController.resolvedEnablement(Self.closeSession, context: context) == false)
        #expect(MainSplitViewController.resolvedEnablement(Self.openSession, context: context) == true)
        #expect(MainSplitViewController.resolvedEnablement(Self.deleteSession, context: context) == true)
    }

    private static let openSession = #selector(MainSplitViewController.openAgentSession(_:))
    private static let closeSession = #selector(MainSplitViewController.closeAgentSession(_:))
    private static let deleteSession = #selector(MainSplitViewController.deleteAgentSession(_:))

    /// The two delegate-filled lists under File > Session build their rows when they open, so the
    /// menu walk above never sees them. Each row's selector still has to reach the window and be
    /// decided there, which is the whole reason they carry no target.
    @Test("Every delegate-filled row reaches the window and is decided there")
    func delegateFilledRowsAreAnsweredAndDecided() {
        let selectors: [Selector] = [
            AgentSessionMenuDelegate.action,
            ConversationHistoryMenuDelegate.action,
            ImportFormatMenuDelegate.action,
            ContentModeMenuDelegate.action,
        ]
        for selector in selectors {
            let name = NSStringFromSelector(selector)
            #expect(MainSplitViewController.instancesRespond(to: selector), "\(name) reaches nothing")
            guard !liveValidatedSelectors.contains(selector) else { continue }
            #expect(
                MainSplitViewController.resolvedEnablement(selector, context: MenuValidationContext()) != nil,
                "\(name) has no arm, so it stays lit over a window that cannot run it"
            )
        }
    }

    /// The assistant's conversation commands, which had no selector at all before: the pane header's
    /// buttons reached `AIChatViewModel` from inside SwiftUI, so the menu bar could not carry them.
    /// They answer in both content modes, because the conversation is one thing shown two ways.
    @Test("The conversation commands follow the assistant rather than the mode")
    func conversationCommandsFollowTheAssistant() {
        let newConversation = #selector(MainSplitViewController.newAIConversation(_:))
        let switchConversation = #selector(MainSplitViewController.switchAIConversation(_:))
        let clearConversations = #selector(MainSplitViewController.clearAIConversations(_:))

        var context = MenuValidationContext()
        #expect(MainSplitViewController.resolvedEnablement(newConversation, context: context) == false)
        #expect(MainSplitViewController.resolvedEnablement(switchConversation, context: context) == false)
        #expect(MainSplitViewController.resolvedEnablement(clearConversations, context: context) == false)

        context.hasAssistantConversation = true
        #expect(MainSplitViewController.resolvedEnablement(newConversation, context: context) == true)
        #expect(
            MainSplitViewController.resolvedEnablement(clearConversations, context: context) == false,
            "Nothing stored is nothing to clear"
        )

        context.hasStoredConversations = true
        #expect(MainSplitViewController.resolvedEnablement(switchConversation, context: context) == true)
        #expect(MainSplitViewController.resolvedEnablement(clearConversations, context: context) == true)

        context.isAgentMode = true
        #expect(MainSplitViewController.resolvedEnablement(newConversation, context: context) == true)
        #expect(MainSplitViewController.resolvedEnablement(clearConversations, context: context) == true)
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
