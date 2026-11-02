//
//  ShortcutUniquenessTests.swift
//  TableProTests
//
//  AppKit silently blanks the key equivalent of one of two menu items that share it.
//

import Foundation
@testable import TablePro
import Testing

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

    // Apple's standard-shortcuts table gives an inspector Option-Command-I.
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

    // Listed, not counted: two PRs that each add one merge cleanly into a wrong count, but into the right list.
    @Test("Only the listed actions ship unbound")
    func unboundActionsAreListed() {
        let listed: Set<ShortcutAction> = [
            .manageConnections,
            .copyRelativePath, .removeInvisibleCharacters,
            .copyCellValue, .copyAsCsv, .copyAsCsvWithHeaders, .copyAsMarkdown, .copyAsInClause, .copyAsInsert, .copyAsUpdate,
            .clearSelection, .setValueEmpty, .setValueNull, .setValueDefault, .generateUUIDv4, .generateUUIDv7,
            .setCellsToValue, .restorePreviousValues,
            .closeOtherTabs, .closeTabsForOtherDatabases, .closeAllTabs, .pinTab,
            .showTablesList, .showFavoritesList,
            .newAgentSession, .openAgentSession, .closeAgentSession, .deleteAgentSession, .newAIConversation,
            .showPreviousWindowTab, .showNextWindowTab,
            .toggleBreakpoint,
        ]
        let unbound = Set(ShortcutAction.allCases.filter { KeyboardSettings.defaultShortcuts[$0] == nil })
        let unlisted = unbound.subtracting(listed).map(\.rawValue).sorted()
        let nowBound = listed.subtracting(unbound).map(\.rawValue).sorted()
        #expect(unlisted.isEmpty, "Unbound but not listed: \(unlisted)")
        #expect(nowBound.isEmpty, "Listed but given a default: \(nowBound)")
        for action in unbound {
            #expect(KeyboardSettings.default.shortcut(for: action) == nil, "\(action.rawValue)")
        }
    }

    // Each is a new row in Settings; the exhaustive switches force an arm, this holds that it names something.
    @Test("Each newly rebindable command is listed under a category with a name", arguments: [
        ShortcutAction.showTablesList, .showFavoritesList, .restorePreviousValues,
        .newAgentSession, .openAgentSession, .closeAgentSession, .deleteAgentSession, .newAIConversation,
        .copyPath, .copyRelativePath, .setCellsToValue, .pinTab,
        .showServerDashboard, .showQueryInsights,
    ])
    func newlyRebindableCommandsAreListable(action: ShortcutAction) {
        #expect(!action.displayName.isEmpty)
        #expect(ShortcutCategory.allCases.contains(action.category))
    }

    // Left to the context switch's `default:` it would be `.global`, and the recorder would call a grid combo free for it.
    @Test("Restore Previous Values is a data-grid command")
    func restorePreviousValuesIsAGridCommand() {
        #expect(ShortcutAction.restorePreviousValues.context == .dataGrid)
        #expect(ShortcutAction.restorePreviousValues.category == .dataGrid)
    }
}
