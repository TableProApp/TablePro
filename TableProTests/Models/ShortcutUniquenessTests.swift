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
}
