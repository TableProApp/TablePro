import Foundation
import TableProSQLQuoting

public enum SQLIdentifierCase: String, Codable, CaseIterable, Sendable {
    case asStored
    case lower
    case upper
    case matchTyped

    public static let `default` = SQLIdentifierCase.asStored

    // Without a typed prefix, matching the typing has nothing to match, so it reads as stored.
    public var recasesWithoutTyping: Bool {
        switch self {
        case .lower, .upper: return true
        case .asStored, .matchTyped: return false
        }
    }
}

public enum SQLIdentifierFolding: Sendable, Equatable {
    case upper
    case lower
}

// How an engine resolves an unquoted name: folded to one case, unless it is reserved.
public struct SQLIdentifierRules: Sendable {
    public let folding: SQLIdentifierFolding
    public let reservedWords: Set<String>
    public let quote: SQLIdentifierQuote

    public init(folding: SQLIdentifierFolding, reservedWords: Set<String>, quote: SQLIdentifierQuote = .doubleQuote) {
        self.folding = folding
        self.reservedWords = Set(reservedWords.map { $0.uppercased() })
        self.quote = quote
    }
}

// What a completion's name is made of. A catalog part is spelled by the connection's rules; a statement part is
// what the user wrote, an alias or a reference, and is never re-cased.
public struct SQLCompletionIdentifier: Sendable, Hashable {
    public enum Part: Sendable, Hashable {
        case catalog(String)
        case statement(String, quoted: Bool)
    }

    public let parts: [Part]

    public init(_ parts: [Part]) {
        self.parts = parts
    }

    public static func catalog(_ name: String) -> SQLCompletionIdentifier {
        SQLCompletionIdentifier([.catalog(name)])
    }

    // Each part as stored or as written, with no quotes.
    public var plainText: String {
        parts.map { part in
            switch part {
            case .catalog(let name): return name
            case .statement(let text, _): return text
            }
        }.joined(separator: ".")
    }
}

public struct SQLCompletionColumnPair: Sendable, Hashable {
    public let left: SQLCompletionIdentifier
    public let right: SQLCompletionIdentifier

    public init(left: SQLCompletionIdentifier, right: SQLCompletionIdentifier) {
        self.left = left
        self.right = right
    }

    // One equality per pair, in key order.
    public static func condition(_ sides: [(left: String, right: String)]) -> String {
        sides.map { "\($0.left) = \($0.right)" }.joined(separator: " AND ")
    }
}

// Whether the token being completed already opened a quoted name, and whether that quote is closed.
public enum SQLIdentifierTokenQuoting: Sendable, Equatable {
    case none
    case opened
    case enclosed

    public init(_ quotedName: SQLQuotedName?) {
        guard let quotedName else {
            self = .none
            return
        }
        self = quotedName.close == nil ? .opened : .enclosed
    }
}

public struct SQLIdentifierSpelling: Sendable {
    public enum Form: Sendable, Equatable {
        case bare(String)
        case quoted
    }

    public let rules: SQLIdentifierRules
    public let policy: SQLIdentifierCase

    public init(rules: SQLIdentifierRules, policy: SQLIdentifierCase) {
        self.rules = rules
        self.policy = policy
    }

    // A name keeps working bare only when the engine folds it back to itself, so any other spelling of it would too.
    public func form(of name: String, typedPrefix: String = "") -> Form {
        guard canStayBare(name) else { return .quoted }
        switch policy {
        case .asStored:
            return .bare(name)
        case .lower:
            return .bare(name.lowercased())
        case .upper:
            return .bare(name.uppercased())
        case .matchTyped:
            guard let scalar = typedPrefix.unicodeScalars.first(where: { $0.properties.isCased }) else {
                return .bare(name)
            }
            return .bare(scalar.properties.isLowercase ? name.lowercased() : name.uppercased())
        }
    }

    public func quoted(_ name: String) -> String {
        SQLQuoting.identifier(name, quote: rules.quote)
    }

    // A name written into a statement with nothing typed: as stored keeps the caller's own spelling.
    public func statementName(_ name: String, quotedBy quote: (String) -> String) -> String {
        guard policy.recasesWithoutTyping, case .bare(let text) = form(of: name) else { return quote(name) }
        return text
    }

    // `label` and `insertText` are rewritten together; `filterText` and `matchedRanges` stay, since a re-cased name
    // has the same length and every quote goes into `insertText` only.
    public func applied(
        to items: [SQLCompletionItem],
        typedPrefix: String,
        quoting: SQLIdentifierTokenQuoting
    ) -> [SQLCompletionItem] {
        items.map { spelled($0, typedPrefix: typedPrefix, quoting: quoting) }
    }

    private func spelled(
        _ item: SQLCompletionItem,
        typedPrefix: String,
        quoting: SQLIdentifierTokenQuoting
    ) -> SQLCompletionItem {
        if !item.columnPairs.isEmpty {
            // The typed text is a qualifier, which says nothing about how the columns are cased.
            guard quoting == .none else { return item }
            let sides = item.columnPairs.map { pair in
                (left: spelled(pair.left.parts, typedPrefix: ""), right: spelled(pair.right.parts, typedPrefix: ""))
            }
            return item.recased(
                label: SQLCompletionColumnPair.condition(sides.map { (left: $0.left.label, right: $0.right.label) }),
                insertText: SQLCompletionColumnPair.condition(sides.map { (left: $0.left.text, right: $0.right.text) })
            )
        }
        guard let identifier = item.identifier else { return item }
        if quoting != .none, identifier.parts.count == 1, case .catalog(let name) = identifier.parts[0] {
            // The user's own quote asks for the exact name: inside a closed pair it goes in without the pair.
            let text = quoting == .enclosed ? String(quoted(name).unicodeScalars.dropFirst().dropLast()) : quoted(name)
            return item.recased(label: name, insertText: text)
        }
        // A qualified reference replaces the user's quotes, so it is spelled as if none were typed.
        guard quoting != .enclosed || item.isQualifiedReference else { return item }

        let name = spelled(identifier.parts, typedPrefix: typedPrefix)
        return item.recased(label: name.label, insertText: name.text)
    }

    private func spelled(_ parts: [SQLCompletionIdentifier.Part], typedPrefix: String) -> (label: String, text: String) {
        var labels: [String] = []
        var texts: [String] = []
        for part in parts {
            switch part {
            case .catalog(let name):
                switch form(of: name, typedPrefix: typedPrefix) {
                case .bare(let text):
                    labels.append(text)
                    texts.append(text)
                case .quoted:
                    labels.append(name)
                    texts.append(quoted(name))
                }
            case .statement(let text, let isQuoted):
                labels.append(text)
                texts.append(isQuoted ? quoted(text) : text)
            }
        }
        return (labels.joined(separator: "."), texts.joined(separator: "."))
    }

    private func canStayBare(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        guard let first = scalars.first, Self.isASCIILetter(first),
              scalars.allSatisfy({ Self.isASCIILetter($0) || Self.isDigit($0) || $0 == "_" }) else { return false }
        let folded = rules.folding == .upper ? name.uppercased() : name.lowercased()
        return name == folded && !rules.reservedWords.contains(name.uppercased())
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value)
    }
}
