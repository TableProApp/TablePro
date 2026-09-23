//
//  ShortcutUniquenessTests.swift
//  TableProTests
//
//  Two menu items cannot share a key equivalent: AppKit blanks the loser's, silently, with no
//  warning at build time and nothing on screen to say which command lost. Nothing checked this
//  before, so a new binding could take a shipped one away.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Keyboard shortcut uniqueness")
struct ShortcutUniquenessTests {
    @Test("No two actions ship the same default key equivalent")
    func defaultsAreUnique() {
        var owners: [BoundKey: [ShortcutAction]] = [:]
        for (action, key) in KeyboardSettings.defaultShortcuts {
            owners[key, default: []].append(action)
        }
        let collisions = owners.filter { $0.value.count > 1 }
        let described = collisions
            .map { "\($0.key): \($0.value.map(\.rawValue).sorted().joined(separator: ", "))" }
            .sorted()
        #expect(collisions.isEmpty, "Actions sharing one key equivalent: \(described)")
    }

    @Test("The two trailing-pane commands do not collide with each other")
    func trailingPaneCommandsAreDistinct() {
        let inspector = KeyboardSettings.defaultShortcuts[.toggleInspector]
        let assistant = KeyboardSettings.defaultShortcuts[.toggleAssistant]

        #expect(inspector != nil)
        #expect(assistant != nil)
        #expect(inspector != assistant)
    }

    /// The shipped inspector binding. Apple's standard-shortcuts table gives Option-Command-I for an
    /// inspector, and changing it would take a documented shortcut away from everyone.
    @Test("The inspector keeps its shipped binding")
    func inspectorBindingIsStable() {
        #expect(KeyboardSettings.defaultShortcuts[.toggleInspector] == .character("i", command: true, option: true))
    }

    @Test("Every action that ships a default is reachable from the action list")
    func everyBoundActionExists() {
        for action in KeyboardSettings.defaultShortcuts.keys {
            #expect(ShortcutAction.allCases.contains(action))
        }
    }

    /// Sixteen actions ship with nothing bound: the six that always did, the eight the connection
    /// window's revamp made rebindable for the first time, and the two window-tab commands, whose
    /// Control-Tab went to the recent-tab switcher. Counted rather than listed, because the number is
    /// the claim: adding a default to one of them is a decision about a combo that is already taken,
    /// and it has to be made on purpose.
    @Test("Sixteen actions ship unbound")
    func unboundActionsAreCounted() {
        let unbound = ShortcutAction.allCases.filter { KeyboardSettings.defaultShortcuts[$0] == nil }
        #expect(unbound.count == 16, "Unbound: \(unbound.map(\.rawValue).sorted())")
        for action in unbound {
            #expect(KeyboardSettings.default.shortcut(for: action) == nil, "\(action.rawValue)")
        }
    }

    /// The eight are new rows in Settings, so each needs a category to be listed under and a name to
    /// be listed by. Both switches are exhaustive, so the compiler already forces an arm; what this
    /// holds is that the arm is not an empty string nobody would recognise.
    @Test("Each newly rebindable command is listed under a category with a name", arguments: [
        ShortcutAction.showTablesList, .showFavoritesList, .restorePreviousValues,
        .newAgentSession, .openAgentSession, .closeAgentSession, .deleteAgentSession, .newAIConversation,
    ])
    func newlyRebindableCommandsAreListable(action: ShortcutAction) {
        #expect(!action.displayName.isEmpty)
        #expect(ShortcutCategory.allCases.contains(action.category))
    }

    /// It reverses rows the grid is showing, so it belongs in the grid's context the way Add Row and
    /// Delete do. Left to the `context` switch's `default:` it would be `.global`, and the recorder
    /// would then call a grid combo free for it.
    @Test("Restore Previous Values is a data-grid command")
    func restorePreviousValuesIsAGridCommand() {
        #expect(ShortcutAction.restorePreviousValues.context == .dataGrid)
        #expect(ShortcutAction.restorePreviousValues.category == .dataGrid)
    }
}
