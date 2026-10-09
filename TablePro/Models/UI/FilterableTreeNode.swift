//
//  FilterableTreeNode.swift
//  TablePro
//

import AppKit
import Foundation

internal protocol FilterableTreeNode: Identifiable {
    var key: String? { get }
    var keyPath: String { get }
    var path: TreeNodePath { get }
    var displayValue: String { get }
    var searchableKey: String? { get }
    var searchableText: String { get }
    var copyableValue: String { get }
    var badgeLabel: String { get }
    var isTruncationMarker: Bool { get }
    var rowContent: TreeRowContent { get }
    var children: [Self] { get }

    func replacingChildren(_ children: [Self]) -> Self
}

internal extension FilterableTreeNode {
    var isContainer: Bool {
        !children.isEmpty
    }

    var accessibilityDescription: String {
        let head = TreeDisplayText.cut(displayValue, limit: 120).text
        guard let key, !key.isEmpty else { return "\(badgeLabel), \(head)" }
        return "\(key), \(badgeLabel), \(head)"
    }
}

// MARK: - Path

/// Where a node sits in its document. Unique per node and equal across two parses of the same
/// text, which neither `id` (the document generation) nor `keyPath` (the copyable path) is.
internal struct TreeNodePath: Hashable, Sendable {
    internal enum Component: Hashable, Sendable {
        case key(String, occurrence: Int)
        case integerKey(Int, occurrence: Int)
        case index(Int)
        case truncationMarker
    }

    /// A path shares its parent's link, so a node costs one link however deep it sits, and the
    /// hash an outline asks for on every item lookup is computed once.
    private final class Link: Sendable {
        let parent: Link?
        let component: Component
        let depth: Int
        let hash: Int

        init(parent: Link?, component: Component) {
            self.parent = parent
            self.component = component
            depth = (parent?.depth ?? 0) + 1
            var hasher = Hasher()
            hasher.combine(parent?.hash)
            hasher.combine(component)
            hash = hasher.finalize()
        }
    }

    private let link: Link?

    private init(link: Link?) {
        self.link = link
    }

    internal static let root = TreeNodePath(link: nil)

    internal var parent: TreeNodePath? {
        guard let link else { return nil }
        return TreeNodePath(link: link.parent)
    }

    internal var lastComponent: Component? {
        link?.component
    }

    internal var depth: Int {
        link?.depth ?? 0
    }

    internal var components: [Component] {
        var reversed: [Component] = []
        var current = link
        while let link = current {
            reversed.append(link.component)
            current = link.parent
        }
        return reversed.reversed()
    }

    internal func appending(_ component: Component) -> TreeNodePath {
        TreeNodePath(link: Link(parent: link, component: component))
    }

    internal func hasAncestor(in paths: Set<TreeNodePath>) -> Bool {
        var current = parent
        while let ancestor = current {
            if paths.contains(ancestor) { return true }
            current = ancestor.parent
        }
        return false
    }

    internal static func == (lhs: TreeNodePath, rhs: TreeNodePath) -> Bool {
        var left = lhs.link
        var right = rhs.link
        while left !== right {
            guard let leftLink = left, let rightLink = right,
                  leftLink.hash == rightLink.hash,
                  leftLink.depth == rightLink.depth,
                  leftLink.component == rightLink.component else { return false }
            left = leftLink.parent
            right = rightLink.parent
        }
        return true
    }

    internal func hash(into hasher: inout Hasher) {
        hasher.combine(link?.hash)
    }
}

extension TreeNodePath: CustomStringConvertible {
    internal var description: String {
        components.reduce(into: "$") { text, component in
            switch component {
            case .key(let name, let occurrence):
                text += occurrence == 0 ? "/\(name)" : "/\(name)#\(occurrence)"
            case .integerKey(let value, let occurrence):
                text += occurrence == 0 ? "/i:\(value)" : "/i:\(value)#\(occurrence)"
            case .index(let index):
                text += "/[\(index)]"
            case .truncationMarker:
                text += "/…"
            }
        }
    }
}

/// Numbers the members of one container, so two members with the same name get different paths.
internal struct TreeSiblingCounter {
    private var names: [String: Int] = [:]
    private var integers: [Int: Int] = [:]

    internal init() {}

    internal mutating func key(_ name: String) -> TreeNodePath.Component {
        let occurrence = names[name, default: 0]
        names[name] = occurrence + 1
        return .key(name, occurrence: occurrence)
    }

    internal mutating func integerKey(_ value: Int) -> TreeNodePath.Component {
        let occurrence = integers[value, default: 0]
        integers[value] = occurrence + 1
        return .integerKey(value, occurrence: occurrence)
    }
}

// MARK: - Row Content

internal enum TreeValueTone: Equatable, Sendable {
    case container
    case string
    case number
    case literal
    case serialized
    case reference
    case muted

    var color: NSColor {
        switch self {
        case .container: return .systemBlue
        case .string: return .systemRed
        case .number: return .systemPurple
        case .literal: return .systemOrange
        case .serialized: return .systemTeal
        case .reference: return .systemGray
        case .muted: return .secondaryLabelColor
        }
    }
}

internal struct TreeRowContent: Equatable, Sendable {
    let key: String?
    let value: String
    /// In UTF-16 units of `value`: between the quotes and before the ellipsis for a string, all of
    /// it otherwise. It is not a range in the raw value, which is escaped and cut to make `value`.
    let valueContentRange: NSRange
    let tone: TreeValueTone
    let typeBadge: String
    let visibilityBadge: String?
    let decoration: TreeValueDecoration
}

internal extension TreeRowContent {
    /// `string` is the raw text of a string node, and nil for every other kind of node.
    init(
        key: String?,
        value: String,
        string: String?,
        isCut: Bool,
        tone: TreeValueTone,
        typeBadge: String,
        visibilityBadge: String?
    ) {
        let length = (value as NSString).length
        let wrapping = isCut ? 3 : 2
        guard let string, length >= wrapping else {
            self.init(
                key: key, value: value, valueContentRange: NSRange(location: 0, length: length),
                tone: tone, typeBadge: typeBadge, visibilityBadge: visibilityBadge, decoration: .none
            )
            return
        }
        self.init(
            key: key, value: value, valueContentRange: NSRange(location: 1, length: length - wrapping),
            tone: tone, typeBadge: typeBadge, visibilityBadge: visibilityBadge,
            decoration: TreeValueClassifier.classify(string)
        )
    }
}

// MARK: - Display Text

internal enum TreeDisplayText {
    /// The longest run of whole characters that fits `limit` UTF-16 units, so a cut never lands
    /// inside a surrogate pair or an emoji sequence.
    static func cut(_ text: String, limit: Int) -> (text: String, isCut: Bool) {
        head(of: text, limit: limit) { scalar, output in
            output.unicodeScalars.append(scalar)
            return UTF16.width(scalar)
        }
    }

    /// The value as a JSON string literal, cut to `limit` units of escaped text with an ellipsis.
    static func quoted(_ raw: String, limit: Int) -> (text: String, isCut: Bool) {
        if fitsUnescaped(raw, limit: limit) { return ("\"\(raw)\"", false) }
        let fitted = head(of: raw, limit: limit, appending: appendEscaped)
        return ("\"\(fitted.text)\(fitted.isCut ? "…" : "")\"", fitted.isCut)
    }

    /// UTF-8 length bounds UTF-16 length, so a value this short is only cut if an escape lengthens it.
    private static func fitsUnescaped(_ raw: String, limit: Int) -> Bool {
        var count = 0
        for byte in raw.utf8 {
            count += 1
            guard count <= limit, byte >= 0x20, byte != 0x22, byte != 0x5C else { return false }
        }
        return true
    }

    static func jsonQuoted(_ raw: String) -> String {
        var output = "\""
        for scalar in raw.unicodeScalars {
            _ = appendEscaped(scalar, to: &output)
        }
        return output + "\""
    }

    private static func appendEscaped(_ scalar: Unicode.Scalar, to output: inout String) -> Int {
        switch scalar {
        case "\"": output += "\\\""
        case "\\": output += "\\\\"
        case "\n": output += "\\n"
        case "\r": output += "\\r"
        case "\t": output += "\\t"
        default:
            guard scalar.value < 0x20 else {
                output.unicodeScalars.append(scalar)
                return UTF16.width(scalar)
            }
            output += String(format: "\\u%04x", scalar.value)
            return 6
        }
        return 2
    }

    /// Reads at most `limit + 1` scalars. That many always overflow the limit, so a loop that
    /// runs to the end has seen the whole text.
    private static func head(
        of text: String,
        limit: Int,
        appending: (Unicode.Scalar, inout String) -> Int
    ) -> (text: String, isCut: Bool) {
        let window = Substring(text.unicodeScalars.prefix(limit + 1))
        var output = ""
        var piece = ""
        var units = 0
        for character in window {
            piece.removeAll(keepingCapacity: true)
            var width = 0
            for scalar in character.unicodeScalars {
                width += appending(scalar, &piece)
            }
            guard units + width <= limit else { return (output, true) }
            output += piece
            units += width
        }
        return (output, false)
    }
}

internal enum TreeKeyPathSyntax {
    /// `$."a.b"` is the spelling SQLite, DuckDB, MariaDB and PostgreSQL all resolve to the key
    /// `a.b`. `$.a.b` reads another node in each of them and `$["a.b"]` fails in each.
    static func member(_ key: String) -> String {
        guard !isIdentifier(key) else { return key }
        var quoted = "\""
        for scalar in key.unicodeScalars {
            if scalar == "\"" || scalar == "\\" { quoted += "\\" }
            quoted.unicodeScalars.append(scalar)
        }
        return quoted + "\""
    }

    private static func isIdentifier(_ key: String) -> Bool {
        var isFirst = true
        for byte in key.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "_"):
                break
            case UInt8(ascii: "0")...UInt8(ascii: "9") where !isFirst:
                break
            default:
                return false
            }
            isFirst = false
        }
        return !isFirst
    }
}

// MARK: - Summaries

/// Looked up once per document rather than once per container, and injectable because the wording
/// follows the language the app runs in.
internal struct TreeSummaryFormats: Sendable {
    internal struct Count: Sendable {
        let one: String
        let many: String

        func text(_ count: Int) -> String {
            count == 1 ? one : String(format: many, count)
        }
    }

    let keys: Count
    let items: Count
    let properties: Count

    static var localized: TreeSummaryFormats {
        TreeSummaryFormats(
            keys: Count(one: String(localized: "1 key"), many: String(localized: "%lld keys")),
            items: Count(one: String(localized: "1 item"), many: String(localized: "%lld items")),
            properties: Count(one: String(localized: "1 property"), many: String(localized: "%lld properties"))
        )
    }
}
