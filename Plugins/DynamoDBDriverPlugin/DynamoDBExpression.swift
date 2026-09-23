import Foundation

/// A document path such as `address.city` or `items[0].sku`.
struct DynamoDBAttributePath: Sendable, Equatable, Hashable {
    enum Segment: Sendable, Equatable, Hashable {
        case name(String)
        case index(Int)
    }

    let segments: [Segment]

    var root: String {
        guard case .name(let name) = segments.first else { return "" }
        return name
    }

    var isTopLevel: Bool { segments.count == 1 }

    init(segments: [Segment]) {
        self.segments = segments
    }

    init(attribute: String) {
        self.segments = [.name(attribute)]
    }

    /// Reads `text` as a path, unless it is the name of an attribute the grid shows: an attribute
    /// may be named `a.b`, and the filter bar sends that name, not a path.
    static func parse(_ text: String, knownAttributes: Set<String>) -> DynamoDBAttributePath {
        if knownAttributes.contains(text) || !(text.contains(".") || text.contains("[")) {
            return DynamoDBAttributePath(attribute: text)
        }
        var segments: [Segment] = []
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            switch character {
            case ".":
                if !current.isEmpty { segments.append(.name(current)) }
                current = ""
                index = text.index(after: index)
            case "[":
                if !current.isEmpty { segments.append(.name(current)) }
                current = ""
                guard let close = text[index...].firstIndex(of: "]"),
                      let position = Int(text[text.index(after: index)..<close]),
                      position >= 0
                else { return DynamoDBAttributePath(attribute: text) }
                segments.append(.index(position))
                index = text.index(after: close)
            default:
                current.append(character)
                index = text.index(after: index)
            }
        }
        if !current.isEmpty { segments.append(.name(current)) }
        guard case .name = segments.first else { return DynamoDBAttributePath(attribute: text) }
        return DynamoDBAttributePath(segments: segments)
    }

    func value(in item: DynamoDBItem) -> DynamoDBAttributeValue? {
        var current: DynamoDBAttributeValue? = item[root]
        for segment in segments.dropFirst() {
            switch (segment, current) {
            case (.name(let name), .map(let entries)?):
                current = entries[name]
            case (.index(let position), .list(let items)?):
                current = items.indices.contains(position) ? items[position] : nil
            default:
                return nil
            }
        }
        return current
    }
}

/// Collects `#name` and `:value` placeholders while an expression is written.
///
/// Every name goes through a placeholder. DynamoDB reserves 573 words (`name`, `status`, `data`,
/// `date` among them) and rejects `-` in a raw name, and it rejects a placeholder that is declared
/// but unused, so a placeholder exists only once something refers to it.
struct DynamoDBExpressionContext: Sendable, Equatable {
    private(set) var names: [String: String] = [:]
    private(set) var values: [String: DynamoDBAttributeValue] = [:]
    private var placeholderByName: [String: String] = [:]

    mutating func name(_ attribute: String) -> String {
        if let existing = placeholderByName[attribute] { return existing }
        let placeholder = unique("#" + Self.sanitized(attribute), in: Set(names.keys))
        names[placeholder] = attribute
        placeholderByName[attribute] = placeholder
        return placeholder
    }

    mutating func path(_ path: DynamoDBAttributePath) -> String {
        var rendered = ""
        for segment in path.segments {
            switch segment {
            case .name(let attribute):
                rendered += (rendered.isEmpty ? "" : ".") + name(attribute)
            case .index(let position):
                rendered += "[\(position)]"
            }
        }
        return rendered
    }

    mutating func value(_ value: DynamoDBAttributeValue, hint: String) -> String {
        if let existing = values.first(where: { $0.value == value && $0.key.hasPrefix(":" + Self.sanitized(hint)) }) {
            return existing.key
        }
        let placeholder = unique(":" + Self.sanitized(hint), in: Set(values.keys))
        values[placeholder] = value
        return placeholder
    }

    /// Adds the placeholders to a request body, and only the ones in use.
    func apply(to body: inout [String: DynamoDBJSON]) {
        if !names.isEmpty {
            body["ExpressionAttributeNames"] = .object(names.mapValues(DynamoDBJSON.string))
        }
        if !values.isEmpty {
            body["ExpressionAttributeValues"] = .object(values.mapValues(\.wireJSON))
        }
    }

    private func unique(_ base: String, in taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var counter = 2
        while taken.contains("\(base)\(counter)") { counter += 1 }
        return "\(base)\(counter)"
    }

    private static func sanitized(_ text: String) -> String {
        let allowed = text.unicodeScalars.map { scalar -> Character in
            let isAlphanumeric = (scalar.value < 128) && (CharacterSet.alphanumerics.contains(scalar))
            return isAlphanumeric ? Character(scalar) : "_"
        }
        var result = String(allowed.prefix(40))
        if result.isEmpty || result.first?.isNumber == true {
            result = "a" + result
        }
        return result
    }
}
