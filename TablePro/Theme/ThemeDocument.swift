import Foundation

internal indirect enum ThemeJSONNode: Decodable {
    case string(String)
    case number(Int)
    case object([String: ThemeJSONNode])

    internal init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .number(value)
            return
        }
        self = .object(try container.decode([String: ThemeJSONNode].self))
    }

    internal var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    internal var intValue: Int? {
        if case let .number(value) = self { return value }
        return nil
    }

    internal func flattened(prefix: String = "") -> [String: String] {
        switch self {
        case let .string(value):
            return prefix.isEmpty ? [:] : [prefix: value]
        case .number:
            return [:]
        case let .object(children):
            var result: [String: String] = [:]
            for (key, child) in children {
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                result.merge(child.flattened(prefix: path)) { _, new in new }
            }
            return result
        }
    }
}

/// The theme file format, and the only place a file can be rejected. The previous decoder read
/// every key with `decodeIfPresent` and a Default Light fallback, so an empty object and a VS Code
/// theme both decoded "successfully" and rendered as Default Light under the file's own name.
internal struct ThemeDocument {
    internal let schema: Int
    internal let id: String
    internal let name: String
    internal let author: String
    internal let appearance: ThemeAppearance
    internal let colors: [ThemeSlot: ThemeColorValue]

    private enum MetadataKey: String, CaseIterable {
        case schema
        case id
        case name
        case author
        case appearance
    }

    internal init(data: Data) throws {
        let root = try JSONDecoder().decode([String: ThemeJSONNode].self, from: data)

        guard let schema = root[MetadataKey.schema.rawValue]?.intValue else {
            throw ThemeLoadError.missingSchema
        }
        guard schema >= ThemeSchema.oldestSupported else {
            throw ThemeLoadError.schemaTooOld(found: schema, supported: ThemeSchema.current)
        }
        guard schema <= ThemeSchema.current else {
            throw ThemeLoadError.schemaTooNew(found: schema, supported: ThemeSchema.current)
        }
        self.schema = schema

        guard let id = root[MetadataKey.id.rawValue]?.stringValue, !id.isEmpty else {
            throw ThemeLoadError.missingField(MetadataKey.id.rawValue)
        }
        guard ThemeIdentifier.isValid(id) else {
            throw ThemeLoadError.invalidIdentifier(id)
        }
        self.id = id

        guard let name = root[MetadataKey.name.rawValue]?.stringValue, !name.isEmpty else {
            throw ThemeLoadError.missingField(MetadataKey.name.rawValue)
        }
        self.name = name

        guard
            let appearanceRaw = root[MetadataKey.appearance.rawValue]?.stringValue,
            let appearance = ThemeAppearance(rawValue: appearanceRaw)
        else {
            throw ThemeLoadError.missingField(MetadataKey.appearance.rawValue)
        }
        self.appearance = appearance

        author = root[MetadataKey.author.rawValue]?.stringValue ?? ""

        var flat: [String: String] = [:]
        for (key, node) in root where MetadataKey(rawValue: key) == nil {
            flat.merge(node.flattened(prefix: key)) { _, new in new }
        }

        var parsed: [ThemeSlot: ThemeColorValue] = [:]
        var unknown: [String] = []

        for (path, raw) in flat {
            guard let slot = ThemeSlot(rawValue: path) else {
                unknown.append(path)
                continue
            }
            parsed[slot] = try ThemeColorValue(validating: raw)
        }

        guard unknown.isEmpty else {
            throw ThemeLoadError.unknownKeys(unknown.sorted())
        }

        let missing = ThemeSlot.allCases
            .filter { $0.since <= schema && parsed[$0] == nil }
            .map(\.rawValue)

        guard missing.isEmpty else {
            throw ThemeLoadError.missingSlots(missing.sorted())
        }

        colors = parsed
    }

    /// A slot introduced after this file's schema revision takes the same-appearance built-in's
    /// value for that exact slot. Every slot the file's own revision declares is required, so this
    /// never papers over an omission the author could have made.
    internal func resolved() -> ThemeDefinition {
        var definition = BuiltInThemes.default(for: appearance)
        definition.id = id
        definition.name = name
        definition.author = author
        definition.appearance = appearance

        for slot in ThemeSlot.allCases {
            guard let value = colors[slot] else { continue }
            definition[keyPath: slot.keyPath] = value
        }

        return definition
    }
}

internal enum ThemeIdentifier {
    private static let pattern = #"^[A-Za-z0-9._-]+$"#

    internal static func isValid(_ id: String) -> Bool {
        id.range(of: pattern, options: .regularExpression) != nil
            && !id.contains("..")
    }

    internal static func generated() -> String {
        ThemeDefinition.userPrefix + UUID().uuidString.lowercased().prefix(8)
    }
}

internal enum ThemeEncoder {
    internal static func data(for theme: ThemeDefinition) throws -> Data {
        var root: [String: Any] = [
            "schema": ThemeSchema.current,
            "id": theme.id,
            "name": theme.name,
            "author": theme.author,
            "appearance": theme.appearance.rawValue,
        ]

        for slot in ThemeSlot.allCases {
            insert(theme[keyPath: slot.keyPath].rawValue, at: slot.rawValue.components(separatedBy: "."), into: &root)
        }

        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func insert(_ value: String, at path: [String], into container: inout [String: Any]) {
        guard let head = path.first else { return }

        guard path.count > 1 else {
            container[head] = value
            return
        }

        var child = container[head] as? [String: Any] ?? [:]
        insert(value, at: Array(path.dropFirst()), into: &child)
        container[head] = child
    }
}
