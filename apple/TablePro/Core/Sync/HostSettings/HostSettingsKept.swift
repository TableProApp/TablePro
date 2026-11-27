//
//  HostSettingsKept.swift
//  TablePro
//

import Foundation

// What a pull sent that this Mac's stores could not keep as sent: a category no store here names, a theme this build
// cannot read, an option a newer build added, a value this build reads another way. Each goes back to the engine as
// sent while the store still holds what it held right after the pull, so the diff never reads it as this Mac's edit or
// deletion (core ADR 0054, Rules for both providers; 0066, Settings). A local edit of it ends it.
nonisolated struct HostSettingsKept: Codable, Equatable, Sendable {
    enum Shape: Sendable {
        // One value: a theme, or a category no store here names.
        case document
        // An object whose options stand alone.
        case options
        // A list of objects with an `id`, as the slash commands.
        case items
    }

    struct Value: Codable, Equatable, Sendable {
        var sent: Data
        // Nil when the store held nothing.
        var held: Data?

        var byteCount: Int { sent.count + (held?.count ?? 0) }
    }

    enum Entry: Codable, Equatable, Sendable {
        case document(Value)
        case options([String: Value])
        // The members each item lacked, by the item's id. A rename keeps its name out of here, so it goes up.
        case items([String: [String: Data]])
    }

    private(set) var entries: [String: Entry] = [:]
    // The build that last tried the kept values against its stores; a newer one may read them.
    var triedBuild: String?

    var categories: [String] { entries.keys.sorted() }

    var byteCount: Int {
        entries.values.reduce(0) { total, entry in
            switch entry {
            case .document(let value): total + value.byteCount
            case .options(let values): total + values.reduce(0) { $0 + $1.key.utf8.count + $1.value.byteCount }
            case .items(let items):
                total + items.reduce(0) { sum, item in
                    sum + item.key.utf8.count + item.value.reduce(0) { $0 + $1.key.utf8.count + $1.value.count }
                }
            }
        }
    }

    // After a pull wrote `sent` and the store held `held`.
    mutating func record(_ category: String, shape: Shape, sent: Any, held: Any?) throws {
        switch shape {
        case .options:
            if let sentObject = sent as? [String: Any], let heldObject = held as? [String: Any] {
                try recordOptions(category, sent: sentObject, held: heldObject)
                return
            }
        case .items:
            if let sentItems = sent as? [Any], let heldItems = held as? [Any] {
                try recordItems(category, sent: sentItems, held: heldItems)
                return
            }
        case .document:
            break
        }
        let value = Value(sent: try SettingsJSON.canonical(sent), held: try held.map(SettingsJSON.canonical))
        entries[category] = value.sent == value.held ? nil : .document(value)
    }

    // The document to report for a category whose store holds `local`, nil when it holds none.
    mutating func report(_ category: String, local: Any?) throws -> Any? {
        guard let entry = entries[category] else { return local }
        switch entry {
        case .document(let value):
            guard try local.map(SettingsJSON.canonical) == value.held else {
                entries[category] = nil
                return local
            }
            return try SettingsJSON.parse(value.sent)
        case .options(let kept):
            return try reportOptions(category, kept: kept, local: local)
        case .items(let kept):
            return try reportItems(category, kept: kept, local: local)
        }
    }

    mutating func forget(_ category: String) {
        entries[category] = nil
    }

    private mutating func recordOptions(_ category: String, sent: [String: Any], held: [String: Any]) throws {
        var kept: [String: Value] = [:]
        for (key, value) in sent {
            let sentValue = try SettingsJSON.canonical(value)
            let heldValue = try held[key].map(SettingsJSON.canonical)
            if heldValue != sentValue {
                kept[key] = Value(sent: sentValue, held: heldValue)
            }
        }
        entries[category] = kept.isEmpty ? nil : .options(kept)
    }

    // Kept options ride on a document the store holds, so once it holds none, as a layout cleared here, they go with it.
    private mutating func reportOptions(_ category: String, kept: [String: Value], local: Any?) throws -> Any? {
        guard var document = local as? [String: Any] else {
            entries[category] = nil
            return local
        }
        var still: [String: Value] = [:]
        for (key, value) in kept where try document[key].map(SettingsJSON.canonical) == value.held {
            document[key] = try SettingsJSON.parse(value.sent)
            still[key] = value
        }
        entries[category] = still.isEmpty ? nil : .options(still)
        return document
    }

    private mutating func recordItems(_ category: String, sent: [Any], held: [Any]) throws {
        let heldItems = Self.itemsByID(held)
        var kept: [String: [String: Data]] = [:]
        for case let item as [String: Any] in sent {
            guard let id = item["id"] as? String, let heldItem = heldItems[id] else { continue }
            var lacking: [String: Data] = [:]
            for (key, value) in item where heldItem[key] == nil {
                lacking[key] = try SettingsJSON.canonical(value)
            }
            if !lacking.isEmpty {
                kept[id] = lacking
            }
        }
        entries[category] = kept.isEmpty ? nil : .items(kept)
    }

    private mutating func reportItems(_ category: String, kept: [String: [String: Data]], local: Any?) throws -> Any? {
        guard let items = local as? [Any] else {
            entries[category] = nil
            return local
        }
        var still: [String: [String: Data]] = [:]
        var reported: [Any] = []
        for element in items {
            guard var item = element as? [String: Any], let id = item["id"] as? String, let lacking = kept[id] else {
                reported.append(element)
                continue
            }
            var stillLacking: [String: Data] = [:]
            for (key, value) in lacking where item[key] == nil {
                item[key] = try SettingsJSON.parse(value)
                stillLacking[key] = value
            }
            if !stillLacking.isEmpty {
                still[id] = stillLacking
            }
            reported.append(item)
        }
        entries[category] = still.isEmpty ? nil : .items(still)
        return reported
    }

    private static func itemsByID(_ items: [Any]) -> [String: [String: Any]] {
        var byID: [String: [String: Any]] = [:]
        for case let item as [String: Any] in items {
            if let id = item["id"] as? String {
                byID[id] = item
            }
        }
        return byID
    }
}

// JSON as Foundation reads it, compared by its sorted text: key order means nothing, and `true` stays apart from `1`.
nonisolated enum SettingsJSON {
    static func parse(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }
}
