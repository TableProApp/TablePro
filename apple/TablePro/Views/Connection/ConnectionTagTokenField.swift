//
//  ConnectionTagTokenField.swift
//  TablePro
//

import AppKit
import SwiftUI

internal enum ConnectionTagTokens {
    internal enum Entry: Equatable {
        case existing(UUID)
        case new(String)
    }

    // Names are stored lowercased, so a typed "Prod" is the tag "prod". Order is kept, repeats drop.
    internal static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // The field reports unfinished text as a token too, so only a list that lost tokens and gained
    // nothing is a deletion; anything else waits for the field to commit.
    internal static func isRemoval(_ current: [String], from committed: [String]) -> Bool {
        guard current.count < committed.count else { return false }
        var remaining = Dictionary(committed.map { ($0, 1) }, uniquingKeysWith: +)
        for name in current {
            guard let count = remaining[name], count > 0 else { return false }
            remaining[name] = count - 1
        }
        return true
    }

    // How many more of each name one list holds than another.
    internal static func surplus(of names: [String], over base: [String]) -> [String: Int] {
        var counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        for name in base {
            counts[name, default: 0] -= 1
        }
        return counts.filter { $0.value > 0 }
    }

    internal static func resolve(_ names: [String], among tags: [ConnectionTag]) -> [Entry] {
        var seen: Set<String> = []
        var entries: [Entry] = []
        for raw in names {
            let name = normalized(raw)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            if let tag = tags.first(where: { $0.name.lowercased() == name }) {
                entries.append(.existing(tag.id))
            } else {
                entries.append(.new(name))
            }
        }
        return entries
    }
}

// A token's represented object, so text still being typed (a plain String in objectValue) is never
// taken for a finished tag.
internal final class TagToken: NSObject {
    let name: String

    init(name: String) {
        self.name = name
    }
}

internal struct ConnectionTagTokenField: NSViewRepresentable {
    let tokens: [String]
    let completions: [String]
    // Takes the committed names and returns the ones that were kept.
    let onChange: ([String]) -> [String]

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.tokenStyle = .rounded
        field.completionDelay = 0
        field.placeholderString = String(localized: "Add tags")
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(String(localized: "Tags"))
        field.setAccessibilityIdentifier("connection-form-tag-field")
        field.objectValue = tokens.map(TagToken.init(name:))
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        // Only a change from outside, such as a tag picked in the menu, resets the field; a reset
        // would drop the text being typed.
        guard context.coordinator.committed != tokens else { return }
        context.coordinator.committed = tokens
        field.objectValue = tokens.map(TagToken.init(name:))
    }

    @MainActor
    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: ConnectionTagTokenField
        var committed: [String]

        init(parent: ConnectionTagTokenField) {
            self.parent = parent
            self.committed = parent.tokens
        }

        static func names(in field: NSTokenField) -> [String] {
            ((field.objectValue as? [Any]) ?? []).compactMap { ($0 as? TagToken)?.name }
        }

        func tokenField(
            _ tokenField: NSTokenField,
            completionsForSubstring substring: String,
            indexOfToken tokenIndex: Int,
            indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?
        ) -> [Any]? {
            let prefix = ConnectionTagTokens.normalized(substring)
            let taken = Set(committed)
            return parent.completions.filter { $0.hasPrefix(prefix) && !taken.contains($0) }
        }

        func tokenField(_ tokenField: NSTokenField, representedObjectForEditing editingString: String) -> Any? {
            let name = ConnectionTagTokens.normalized(editingString)
            return name.isEmpty ? nil : TagToken(name: name)
        }

        func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject representedObject: Any) -> String? {
            (representedObject as? TagToken)?.name
        }

        func tokenField(_ tokenField: NSTokenField, editingStringForRepresentedObject representedObject: Any) -> String? {
            (representedObject as? TagToken)?.name
        }

        // The one place a typed name becomes a token: Return, a comma, a completion or leaving the field.
        func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
            let added = tokens.compactMap { ($0 as? TagToken)?.name }
            let before = committed
            var next = before
            next.insert(contentsOf: added, at: min(max(index, 0), next.count))
            let accepted = commit(next)
            // A repeat or a tag that could not be stored never becomes a token.
            var room = ConnectionTagTokens.surplus(of: accepted, over: before)
            return tokens.filter { token in
                guard let name = (token as? TagToken)?.name, let count = room[name], count > 0 else { return false }
                room[name] = count - 1
                return true
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            let current = Self.names(in: field)
            guard ConnectionTagTokens.isRemoval(current, from: committed) else { return }
            commit(current)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            let accepted = commit(Self.names(in: field))
            if Self.names(in: field) != accepted {
                field.objectValue = accepted.map(TagToken.init(name:))
            }
        }

        @discardableResult
        private func commit(_ names: [String]) -> [String] {
            guard names != committed else { return committed }
            committed = parent.onChange(names)
            return committed
        }
    }
}
