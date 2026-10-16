import Foundation

/// Format 3 dropped the pane and status groups, made every color optional and removed `system:`
/// values. Format 2 never shipped in a release, and format 1 files carried fonts the app now keeps in
/// settings.
///
/// Adding a slot bumps `current`. The decoder keeps reading every older format, and an unknown key
/// stays an error: a file is refused rather than loaded without colors its author wrote.
public enum ThemeSchema {
    public static let current = 3
}

public enum ThemeIdentifier {
    public static let maximumLength = 128

    private static let pattern = #"^[A-Za-z0-9._-]+$"#

    /// Plain enough to be a file name on every file system TablePro writes to.
    public static func isValid(_ id: String) -> Bool {
        id.utf8.count <= maximumLength
            && id.range(of: pattern, options: .regularExpression) != nil
            && !id.contains("..")
    }

    public static func generated() -> String {
        ThemeDefinition.userPrefix + UUID().uuidString.lowercased().prefix(8)
    }
}

/// The theme file format, and the only place a file can be rejected. Every color is optional: a
/// slot the file leaves out draws its fallback. What is refused is anything that would otherwise
/// load as something the author did not write: an unknown key, an unparseable color, missing
/// metadata, another format.
///
/// Foundation keeps the first of two equal keys at one level, so that duplicate cannot be seen.
public enum ThemeFileFormat {
    public static let maximumTextLength = 100

    /// What `decode` does with a name or author that is not one line of at most `maximumTextLength`.
    public enum TextPolicy: Sendable {
        /// Refuses it: a file someone picked, and every record another Mac sent.
        case strict
        /// Folds it onto one line and cuts it at the cap. TablePro 0.81 wrote names and authors with
        /// neither limit, and a theme it saved still loads; the next save writes the repaired text.
        case repaired
    }

    private enum MetadataKey: String, CaseIterable {
        case schema
        case id
        case name
        case author
        case appearance
    }

    public static func decode(_ data: Data, text policy: TextPolicy = .strict) throws -> ThemeDefinition {
        guard case let .object(root) = try parse(data) else { throw ThemeLoadError.missingSchema }

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
        guard ThemeIdentifier.isValid(id) else { throw ThemeLoadError.invalidIdentifier(id) }

        guard let rawName = root[MetadataKey.name.rawValue]?.stringValue, !trimmed(rawName).isEmpty else {
            throw ThemeLoadError.missingField(MetadataKey.name.rawValue)
        }
        let name = try validatedName(rawName, policy: policy)

        guard
            let appearanceRaw = root[MetadataKey.appearance.rawValue]?.stringValue,
            let appearance = ThemeAppearance(rawValue: appearanceRaw)
        else {
            throw ThemeLoadError.missingField(MetadataKey.appearance.rawValue)
        }

        let author = try validatedAuthor(root[MetadataKey.author.rawValue]?.stringValue ?? "", policy: policy)

        return ThemeDefinition(
            id: id,
            name: name,
            author: author,
            appearance: appearance,
            overrides: try colors(in: root)
        )
    }

    /// Writes what `decode` reads back unchanged: a trimmed name and author, and opaque fills.
    public static func encode(_ theme: ThemeDefinition) throws -> Data {
        guard ThemeIdentifier.isValid(theme.id) else { throw ThemeLoadError.invalidIdentifier(theme.id) }
        let name = try validatedName(theme.name, policy: .strict)

        var root: [String: Any] = [
            MetadataKey.schema.rawValue: ThemeSchema.current,
            MetadataKey.id.rawValue: theme.id,
            MetadataKey.name.rawValue: name,
            MetadataKey.author.rawValue: try validatedAuthor(theme.author, policy: .strict),
            MetadataKey.appearance.rawValue: theme.appearance.rawValue,
        ]

        for slot in ThemeSlot.allCases {
            guard let color = theme.overrides[slot] else { continue }
            let stored = slot.requiresOpaque ? color.opaque : color
            insert(stored.hex, at: slot.rawValue.components(separatedBy: "."), into: &root)
        }

        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    // MARK: - Reading

    /// `JSONDecoder` rather than `JSONSerialization`: its underlying error names the character and
    /// where it is, which is what a person fixing the file by hand needs.
    private static func parse(_ data: Data) throws -> ThemeJSONNode {
        do {
            return try JSONDecoder().decode(ThemeJSONNode.self, from: data)
        } catch let DecodingError.dataCorrupted(context) {
            let underlying = context.underlyingError as NSError?
            throw ThemeLoadError.malformedJSON(detail: underlying?.userInfo[NSDebugDescriptionErrorKey] as? String)
        } catch {
            throw ThemeLoadError.malformedJSON(detail: nil)
        }
    }

    private static func colors(in root: [String: ThemeJSONNode]) throws -> [ThemeSlot: ThemeColor] {
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
            guard parsed[slot] == nil else { throw ThemeLoadError.duplicateKey(leaf.path) }
            guard let raw = leaf.value else { throw ThemeLoadError.invalidColor(leaf.path) }
            let color = try ThemeColor(validating: raw)
            parsed[slot] = slot.requiresOpaque ? color.opaque : color
        }

        guard unknown.isEmpty else { throw ThemeLoadError.unknownKeys(unknown) }
        return parsed
    }

    // MARK: - Metadata

    private static func validatedName(_ raw: String, policy: TextPolicy) throws -> String {
        guard let name = validatedText(raw, policy: policy), !name.isEmpty else { throw ThemeLoadError.invalidName }
        return name
    }

    private static func validatedAuthor(_ raw: String, policy: TextPolicy) throws -> String {
        guard let author = validatedText(raw, policy: policy) else { throw ThemeLoadError.invalidAuthor }
        return author
    }

    private static func validatedText(_ raw: String, policy: TextPolicy) -> String? {
        let text = trimmed(raw)
        if isSingleLine(text), text.count <= maximumTextLength {
            return text
        }
        guard policy == .repaired else { return nil }
        return repaired(text)
    }

    /// Every scalar `isSingleLine` refuses splits words, so the next save's strict check passes.
    private static func repaired(_ text: String) -> String {
        let separators = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        let words = text.components(separatedBy: separators).filter { !$0.isEmpty }
        return String(words.joined(separator: " ").prefix(maximumTextLength))
            .trimmingCharacters(in: .whitespaces)
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `controlCharacters` holds the ASCII line breaks; `newlines` adds the Unicode line and paragraph
    /// separators.
    private static func isSingleLine(_ text: String) -> Bool {
        !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }

    // MARK: - Writing

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

/// A JSON value as far as the format cares. A number is kept only as an integer, which is all the
/// schema field holds; anything else that is not a string or an object is `other`, so the decoder
/// can name it rather than drop it.
private indirect enum ThemeJSONNode: Decodable {
    case string(String)
    case number(Int)
    case object([String: ThemeJSONNode])
    case other

    init(from decoder: Decoder) throws {
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

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case let .number(value) = self else { return nil }
        return value
    }

    /// Every leaf with its dotted path. A leaf that is not a string is kept as `nil`.
    func leaves(prefix: String) -> [(path: String, value: String?)] {
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
