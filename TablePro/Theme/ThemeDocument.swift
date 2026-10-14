import Foundation

internal indirect enum ThemeJSONNode: Decodable {
    case string(String)
    case number(Int)
    case object([String: ThemeJSONNode])
    case other

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
        if let value = try? container.decode([String: ThemeJSONNode].self) {
            self = .object(value)
            return
        }
        self = .other
    }

    internal var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    internal var intValue: Int? {
        if case let .number(value) = self { return value }
        return nil
    }

    /// Every leaf with its dotted path. A leaf that is not a string is kept as `nil`, so the
    /// decoder can report it instead of dropping it.
    internal func leaves(prefix: String = "") -> [(path: String, value: String?)] {
        switch self {
        case let .string(value):
            return [(prefix, value)]
        case .number, .other:
            return [(prefix, nil)]
        case let .object(children):
            return children.flatMap { key, child in
                child.leaves(prefix: prefix.isEmpty ? key : "\(prefix).\(key)")
            }
        }
    }
}

/// The theme file format, and the only place a file can be rejected. Every color is optional: a
/// slot the file leaves out draws in the system color, or for syntax in the same-appearance
/// default's color. What is refused is anything that would otherwise load as something the author
/// did not write: an unknown key, an unparseable color, missing metadata, another format.
internal struct ThemeDocument {
    internal let id: String
    internal let name: String
    internal let author: String
    internal let appearance: ThemeAppearance
    internal let colors: [ThemeSlot: ThemeColor]

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
            if let legacy = root["version"]?.intValue {
                throw ThemeLoadError.schemaTooOld(found: legacy, supported: ThemeSchema.current)
            }
            throw ThemeLoadError.missingSchema
        }
        guard schema >= ThemeSchema.current else {
            throw ThemeLoadError.schemaTooOld(found: schema, supported: ThemeSchema.current)
        }
        guard schema <= ThemeSchema.current else {
            throw ThemeLoadError.schemaTooNew(found: schema, supported: ThemeSchema.current)
        }

        guard let id = root[MetadataKey.id.rawValue]?.stringValue, !id.isEmpty else {
            throw ThemeLoadError.missingField(MetadataKey.id.rawValue)
        }
        guard ThemeIdentifier.isValid(id) else {
            throw ThemeLoadError.invalidIdentifier(id)
        }
        self.id = id

        guard let name = root[MetadataKey.name.rawValue]?.stringValue,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
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

        let leaves = root
            .filter { MetadataKey(rawValue: $0.key) == nil }
            .flatMap { key, node in node.leaves(prefix: key) }
            .sorted { $0.path < $1.path }

        var parsed: [ThemeSlot: ThemeColor] = [:]
        var unknown: [String] = []

        for leaf in leaves {
            guard let slot = ThemeSlot(rawValue: leaf.path) else {
                unknown.append(leaf.path)
                continue
            }
            guard parsed[slot] == nil else {
                throw ThemeLoadError.duplicateKey(leaf.path)
            }
            guard let raw = leaf.value else {
                throw ThemeLoadError.invalidColor(leaf.path)
            }
            parsed[slot] = try ThemeColor(validating: raw)
        }

        guard unknown.isEmpty else {
            throw ThemeLoadError.unknownKeys(unknown)
        }

        colors = parsed
    }

    internal func definition() -> ThemeDefinition {
        ThemeDefinition(id: id, name: name, author: author, appearance: appearance, overrides: colors)
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
            guard let color = theme.overrides[slot] else { continue }
            insert(color.hex, at: slot.rawValue.components(separatedBy: "."), into: &root)
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
