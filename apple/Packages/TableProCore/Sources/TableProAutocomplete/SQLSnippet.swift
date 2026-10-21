import Foundation

// The TextMate tab stop forms with braces only: a bare `$1`, `$$` or `$tag$` is a PostgreSQL parameter or dollar quote.
public struct SQLSnippet: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public let number: Int
        public let ranges: [NSRange]  // UTF-16, in document order; a second range mirrors the first
        public let choices: [String]
    }

    public let text: String
    public let fields: [Field]  // ascending number, the order Tab visits them
    public let finalRange: NSRange?  // nil puts the final caret at the end of the text

    public static func parse(_ template: String) -> SQLSnippet? {
        var parser = Parser(units: Array(template.utf16))
        guard let nodes = parser.topLevel() else { return nil }
        var renderer = Renderer(nodes: nodes)
        renderer.render(nodes, enclosing: [])
        guard !renderer.exceededWork else { return nil }

        let text = String(decoding: renderer.output, as: UTF16.self)
        let fields = renderer.ranges.keys.sorted().map { number in
            Field(
                number: number,
                ranges: renderer.ranges[number, default: []].sorted { $0.location < $1.location },
                choices: renderer.choices[number] ?? []
            )
        }
        guard !fields.isEmpty || renderer.finalRange != nil || text != template else { return nil }
        return SQLSnippet(text: text, fields: fields, finalRange: renderer.finalRange)
    }
}

private enum Unit {
    static let dollar = UInt16(UInt8(ascii: "$"))
    static let openBrace = UInt16(UInt8(ascii: "{"))
    static let closeBrace = UInt16(UInt8(ascii: "}"))
    static let colon = UInt16(UInt8(ascii: ":"))
    static let pipe = UInt16(UInt8(ascii: "|"))
    static let comma = UInt16(UInt8(ascii: ","))
    static let backslash = UInt16(UInt8(ascii: "\\"))
    static let semicolon = UInt16(UInt8(ascii: ";"))
    static let zero = UInt16(UInt8(ascii: "0"))
    static let nine = UInt16(UInt8(ascii: "9"))
}

private struct Stop {
    let id: Int
    let number: Int
    let children: [Node]
    let choices: [String]?
}

private enum Node {
    case text([UInt16])
    case stop(Stop)
    case marker
}

// Once `${N:` or `${N|` is read the field must close; one left open leaves the whole template as written, so a
// parse never backtracks and stays linear in the template's length.
private struct Parser {
    private static let maximumDepth = 16
    private static let maximumNumber = 9_999

    let units: [UInt16]
    private var index = 0
    private var depth = 0
    private var nextID = 0
    private var failed = false

    init(units: [UInt16]) {
        self.units = units
    }

    mutating func topLevel() -> [Node]? {
        let nodes = sequence(nested: false)
        return failed ? nil : nodes
    }

    private mutating func sequence(nested: Bool) -> [Node]? {
        var nodes: [Node] = []
        var literal: [UInt16] = []
        func flush() {
            guard !literal.isEmpty else { return }
            nodes.append(.text(literal))
            literal = []
        }

        while index < units.count {
            let unit = units[index]
            if unit == Unit.backslash, let escaped = escape(nested: nested) {
                literal.append(contentsOf: escaped)
                continue
            }
            if nested, unit == Unit.closeBrace {
                index += 1
                flush()
                return nodes
            }
            if unit == Unit.dollar {
                let stop = tabStop()
                if failed { return nil }
                if let stop {
                    flush()
                    nodes.append(.stop(stop))
                    continue
                }
            }
            if !nested, unit == Unit.semicolon, at(index + 1) == Unit.semicolon {
                index += 2
                flush()
                nodes.append(.marker)
                continue
            }
            literal.append(unit)
            index += 1
        }

        if nested {
            failed = true
            return nil
        }
        flush()
        return nodes
    }

    // Inside a default `\}`, `\$` and `\\`; at the top level only `\${`, so a backslash in SQL text stays as written.
    private mutating func escape(nested: Bool) -> [UInt16]? {
        guard let next = at(index + 1) else { return nil }
        if nested, next == Unit.closeBrace || next == Unit.dollar || next == Unit.backslash {
            index += 2
            return [next]
        }
        if !nested, next == Unit.dollar, at(index + 2) == Unit.openBrace {
            index += 3
            return [Unit.dollar, Unit.openBrace]
        }
        return nil
    }

    // Nil without `failed` means the text is not a tab stop and stays literal.
    private mutating func tabStop() -> Stop? {
        guard at(index + 1) == Unit.openBrace, let first = at(index + 2), isDigit(first) else { return nil }

        var cursor = index + 2
        var number = 0
        while let unit = at(cursor), isDigit(unit) {
            number = number * 10 + Int(unit - Unit.zero)
            guard number <= Self.maximumNumber else { return nil }
            cursor += 1
        }

        switch at(cursor) {
        case .some(Unit.closeBrace):
            index = cursor + 1
            return makeStop(number: number, children: [], choices: nil)
        case .some(Unit.colon):
            guard depth < Self.maximumDepth else {
                failed = true
                return nil
            }
            index = cursor + 1
            depth += 1
            defer { depth -= 1 }
            return sequence(nested: true).map { makeStop(number: number, children: $0, choices: nil) }
        case .some(Unit.pipe):
            index = cursor + 1
            return choiceList().map { makeStop(number: number, children: [], choices: $0) }
        default:
            return nil
        }
    }

    private mutating func choiceList() -> [String]? {
        var choices: [String] = []
        var current: [UInt16] = []
        while let unit = at(index) {
            if unit == Unit.backslash, let next = at(index + 1),
               next == Unit.comma || next == Unit.pipe || next == Unit.backslash {
                current.append(next)
                index += 2
                continue
            }
            if unit == Unit.comma {
                choices.append(String(decoding: current, as: UTF16.self))
                current = []
                index += 1
                continue
            }
            if unit == Unit.pipe {
                guard at(index + 1) == Unit.closeBrace else { break }
                index += 2
                choices.append(String(decoding: current, as: UTF16.self))
                return choices
            }
            current.append(unit)
            index += 1
        }
        failed = true
        return nil
    }

    private mutating func makeStop(number: Int, children: [Node], choices: [String]?) -> Stop {
        nextID += 1
        return Stop(id: nextID, number: number, children: children, choices: choices)
    }

    private func at(_ position: Int) -> UInt16? {
        position < units.count ? units[position] : nil
    }

    private func isDigit(_ unit: UInt16) -> Bool {
        unit >= Unit.zero && unit <= Unit.nine
    }
}

private struct Renderer {
    // A mirror repeats its definition, nested mirrors included, so a short template can expand without bound.
    private static let maximumWork = 1_000_000
    private static let maximumDepth = 64

    private(set) var output: [UInt16] = []
    private(set) var ranges: [Int: [NSRange]] = [:]
    private(set) var choices: [Int: [String]] = [:]
    private(set) var finalRange: NSRange?
    private(set) var exceededWork = false

    // The first occurrence with text or choices sets a number's text; the others mirror it.
    private var definitions: [Int: Stop] = [:]
    private let hasExplicitFinal: Bool
    private var work = 0
    private var depth = 0

    init(nodes: [Node]) {
        var definitions: [Int: Stop] = [:]
        var hasExplicitFinal = false
        func collect(_ nodes: [Node]) {
            for case let .stop(stop) in nodes {
                if stop.number == 0 { hasExplicitFinal = true }
                if definitions[stop.number] == nil, !stop.children.isEmpty || stop.choices != nil {
                    definitions[stop.number] = stop
                }
                collect(stop.children)
            }
        }
        collect(nodes)
        self.definitions = definitions
        self.hasExplicitFinal = hasExplicitFinal
    }

    mutating func render(_ nodes: [Node], enclosing: Set<Int>) {
        for node in nodes {
            work += 1
            guard work <= Self.maximumWork else {
                exceededWork = true
                return
            }
            switch node {
            case .text(let units):
                append(units)
            case .marker:
                if !hasExplicitFinal, finalRange == nil {
                    finalRange = NSRange(location: output.count, length: 0)
                } else {
                    append(Array(SQLSnippetMarker.token.utf16))
                }
            case .stop(let stop):
                render(stop, enclosing: enclosing)
            }
        }
    }

    // Every occurrence renders its number's definition, so a field nested in a mirrored default is mirrored too. A
    // field inside an occurrence of its own number has no range of its own: it would overlap its mirror.
    private mutating func render(_ stop: Stop, enclosing: Set<Int>) {
        guard !enclosing.contains(stop.number) else { return }
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maximumDepth else {
            exceededWork = true
            return
        }
        let start = output.count
        let definition = definitions[stop.number] ?? stop
        if let options = definition.choices {
            append(Array((options.first ?? "").utf16))
        } else {
            render(definition.children, enclosing: enclosing.union([stop.number]))
        }
        let range = NSRange(location: start, length: output.count - start)

        if stop.number == 0 {
            if finalRange == nil { finalRange = range }
            return
        }
        ranges[stop.number, default: []].append(range)
        if let options = definition.choices, choices[stop.number] == nil {
            choices[stop.number] = options
        }
    }

    private mutating func append(_ units: [UInt16]) {
        work += units.count
        guard work <= Self.maximumWork else {
            exceededWork = true
            return
        }
        output.append(contentsOf: units)
    }
}
