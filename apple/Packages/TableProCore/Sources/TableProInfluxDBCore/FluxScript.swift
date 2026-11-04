import Foundation

// A Flux script reads only when every package it imports is a local, read-only one and it names no writing function.
// A blocklist of the packages that write or reach out goes stale with each Flux release; this list only grows by review.
public struct FluxScriptReading: Sendable, Equatable {
    public let writes: Bool
    public let reachesOutside: Bool

    public init(writes: Bool, reachesOutside: Bool) {
        self.writes = writes
        self.reachesOutside = reachesOutside
    }

    public init(_ script: String) {
        let (tokens, complete) = FluxLexer.lex(script)
        // An unclosed string, regex or interpolation means this lexer and Flux may disagree on what is code.
        guard complete else {
            self.init(writes: true, reachesOutside: true)
            return
        }
        let imports = FluxImports(tokens)
        let unknownImport = imports.paths.contains { !Self.readOnlyPackages.contains($0) }
        let packageEscapes = Self.usesPackageAsValue(tokens, packages: imports.names)
        let outsideArgument = Self.passesOutsideArgument(tokens)
        let writingName = Self.namesWritingFunction(tokens)
        self.init(
            writes: writingName || unknownImport || packageEscapes,
            reachesOutside: unknownImport || packageEscapes || outsideArgument
        )
    }

    static let readOnlyPackages: Set<String> = [
        "array", "csv", "date", "date/boundaries", "dict", "experimental", "experimental/aggregate",
        "experimental/array", "experimental/table", "generate", "influxdata/influxdb", "influxdata/influxdb/schema",
        "influxdata/influxdb/v1", "interpolate", "join", "json", "math", "regexp", "runtime", "sampledata", "strings",
        "system", "timezone", "types",
    ]

    // `to` and `wideTo` are the writers in the read-only packages above: universe, `experimental` and `influxdb`.
    static let writingNames: Set<String> = ["to", "wideTo"]

    // `from`, `buckets` and `to` take `host` to reach another server; `csv.from` takes `file` to read the server's disk.
    static let outsideLabels: Set<String> = ["host", "file"]

    private static func namesWritingFunction(_ tokens: [FluxToken]) -> Bool {
        tokens.indices.contains { index in
            let token = tokens[index]
            guard token.kind == .identifier || token.kind == .memberString, writingNames.contains(token.text) else {
                return false
            }
            return !tokens.isSymbol(":", at: index + 1)
        }
    }

    // A call argument is `host: x`, `"host": x`, or the shorthand `host` for `host: host`.
    private static func passesOutsideArgument(_ tokens: [FluxToken]) -> Bool {
        tokens.indices.contains { index in
            let token = tokens[index]
            guard token.kind == .identifier || token.kind == .string, outsideLabels.contains(token.text),
                  token.enclosingBracket == "("
            else { return false }
            if tokens.isSymbol(":", at: index + 1) { return true }
            let opensArgument = tokens.isSymbol("(", at: index - 1) || tokens.isSymbol(",", at: index - 1)
            let closesArgument = tokens.isSymbol(",", at: index + 1) || tokens.isSymbol(")", at: index + 1)
            return token.kind == .identifier && opensArgument && closesArgument
        }
    }

    // A package bound to a name, passed on or indexed with `[...]` can reach any member, which the name check cannot follow.
    private static func usesPackageAsValue(_ tokens: [FluxToken], packages: Set<String>) -> Bool {
        tokens.indices.contains { index in
            let token = tokens[index]
            guard token.kind == .identifier, packages.contains(token.text) else { return false }
            if tokens.isSymbol(".", at: index - 1) || tokens.isIdentifier("import", at: index - 1) { return false }
            return !tokens.isSymbol(".", at: index + 1) && !tokens.isSymbol(":", at: index + 1)
        }
    }
}

extension [FluxToken] {
    func isSymbol(_ text: String, at index: Int) -> Bool {
        indices.contains(index) && self[index].kind == .symbol && self[index].text == text
    }

    func isIdentifier(_ text: String, at index: Int) -> Bool {
        indices.contains(index) && self[index].kind == .identifier && self[index].text == text
    }
}

struct FluxImports {
    var paths: [String] = []
    var names: Set<String> = []

    init(_ tokens: [FluxToken]) {
        var index = 0
        while index < tokens.count {
            defer { index += 1 }
            guard tokens[index].kind == .identifier, tokens[index].text == "import" else { continue }
            var cursor = index + 1
            var alias: String?
            if cursor < tokens.count, tokens[cursor].kind == .identifier {
                alias = tokens[cursor].text
                cursor += 1
            }
            guard cursor < tokens.count, tokens[cursor].kind == .string else { continue }
            let path = tokens[cursor].text
            paths.append(path)
            names.insert(alias ?? String(path.split(separator: "/").last ?? Substring(path)))
            index = cursor
        }
    }
}

struct FluxToken: Equatable {
    enum Kind: Equatable {
        case identifier
        case string
        // A string used as a member name, `pkg["name"]`, reported again as the name it reaches.
        case memberString
        case regex
        case number
        case symbol
    }

    let kind: Kind
    let text: String
    let enclosingBracket: Character?
}

// Comments, strings with `${...}` code inside, and regex literals, which Flux tells apart from division by what precedes.
enum FluxLexer {
    static func lex(_ script: String) -> (tokens: [FluxToken], complete: Bool) {
        var lexer = State(Array(script.unicodeScalars))
        lexer.run(untilClosingBrace: false)
        return (lexer.tokens, lexer.complete)
    }

    static func tokens(of script: String) -> [FluxToken] {
        lex(script).tokens
    }

    // Longest first, the way Flux matches `1mo` before `1m`.
    private static let durationUnits = ["mo", "ms", "us", "µs", "ns", "y", "w", "d", "h", "m", "s"]

    private static let keywords: Set<String> = ["and", "or", "not", "return", "if", "then", "else", "exists", "import"]
    private static let twoCharacterSymbols: Set<String> = ["|>", "=~", "!~", "==", "!=", "<=", ">=", "=>", "<-"]

    private struct State {
        let scalars: [Unicode.Scalar]
        var position = 0
        var tokens: [FluxToken] = []
        var brackets: [Character] = []
        var complete = true

        init(_ scalars: [Unicode.Scalar]) {
            self.scalars = scalars
        }

        var regexAllowed: Bool {
            guard let last = tokens.last else { return true }
            switch last.kind {
            case .identifier: return keywords.contains(last.text)
            case .string, .memberString, .regex, .number: return false
            case .symbol: return ![")", "]", "}"].contains(last.text)
            }
        }

        func peek(_ offset: Int = 0) -> Unicode.Scalar? {
            let index = position + offset
            return index < scalars.count ? scalars[index] : nil
        }

        mutating func emit(_ kind: FluxToken.Kind, _ text: String) {
            tokens.append(FluxToken(kind: kind, text: text, enclosingBracket: brackets.last))
        }

        mutating func run(untilClosingBrace: Bool) {
            var depth = 0
            while let scalar = peek() {
                if scalar.properties.isWhitespace {
                    position += 1
                } else if scalar == "/", peek(1) == "/" {
                    while let next = peek(), next != "\n" { position += 1 }
                } else if scalar == "/", regexAllowed {
                    readRegex()
                } else if scalar == "\"" {
                    readString()
                } else if scalar == "_" || scalar.properties.isAlphabetic {
                    readIdentifier()
                } else if ("0" ... "9").contains(scalar) {
                    readNumber()
                } else {
                    if untilClosingBrace {
                        if scalar == "{" { depth += 1 }
                        if scalar == "}" {
                            if depth == 0 {
                                position += 1
                                return
                            }
                            depth -= 1
                        }
                    }
                    readSymbol()
                }
            }
            if untilClosingBrace { complete = false }
        }

        mutating func readSymbol() {
            let first = scalars[position]
            if let second = peek(1) {
                let pair = String(String.UnicodeScalarView([first, second]))
                if twoCharacterSymbols.contains(pair) {
                    position += 2
                    emit(.symbol, pair)
                    return
                }
            }
            position += 1
            let text = String(Character(first))
            switch first {
            case "(", "[", "{":
                emit(.symbol, text)
                brackets.append(Character(first))
            case ")", "]", "}":
                if !brackets.isEmpty { brackets.removeLast() }
                emit(.symbol, text)
            default:
                emit(.symbol, text)
            }
        }

        mutating func readIdentifier() {
            var text = String.UnicodeScalarView()
            while let scalar = peek(), scalar == "_" || scalar.properties.isAlphabetic || ("0" ... "9").contains(scalar) {
                text.append(scalar)
                position += 1
            }
            emit(.identifier, String(text))
        }

        // `1h30m` is one duration and `1.` one float, but `1then` is the number 1 and the keyword `then`.
        mutating func readNumber() {
            skipDigits()
            if peek() == "." {
                position += 1
                skipDigits()
            }
            while let unit = durationUnits.first(where: matches) {
                position += unit.unicodeScalars.count
                guard let next = peek(), ("0" ... "9").contains(next) else { break }
                skipDigits()
            }
            emit(.number, "")
        }

        private mutating func skipDigits() {
            while let scalar = peek(), ("0" ... "9").contains(scalar) { position += 1 }
        }

        private func matches(_ unit: String) -> Bool {
            unit.unicodeScalars.enumerated().allSatisfy { offset, scalar in peek(offset) == scalar }
        }

        // A Flux regex may run over several lines, and `\/` is an escaped slash even right after another backslash.
        mutating func readRegex() {
            position += 1
            while let scalar = peek() {
                position += 1
                if scalar == "\\", peek() == "/" {
                    position += 1
                } else if scalar == "/" {
                    emit(.regex, "")
                    return
                }
            }
            complete = false
            emit(.regex, "")
        }

        mutating func readString() {
            let isMemberName = tokens.isSymbol("[", at: tokens.count - 1) && tokens.dropLast().last.map { token in
                token.kind == .identifier || token.kind == .string
                    || (token.kind == .symbol && [")", "]", "}"].contains(token.text))
            } == true
            position += 1
            var text = String.UnicodeScalarView()
            var closed = false
            while let scalar = peek() {
                position += 1
                if scalar == "\\" {
                    if let escaped = peek() {
                        text.append(escaped)
                        position += 1
                    }
                } else if scalar == "\"" {
                    closed = true
                    break
                } else if scalar == "$", peek() == "{" {
                    position += 1
                    var inner = State(scalars)
                    inner.position = position
                    inner.brackets = brackets + ["{"]
                    inner.run(untilClosingBrace: true)
                    tokens += inner.tokens
                    position = inner.position
                    complete = complete && inner.complete
                } else {
                    text.append(scalar)
                }
            }
            complete = complete && closed
            emit(.string, String(text))
            if isMemberName {
                emit(.memberString, String(text))
            }
        }
    }
}

// The server's own parse of a script, from `POST /api/v2/query/ast`, read with the same rules as `FluxScriptReading`.
// The lexer above picks regex or division from the token before; Flux picks it from the parser state, so the driver
// runs a script only when this reading finds nothing the lexer missed.
public enum FluxAST {
    public static func reading(_ data: Data) throws -> FluxScriptReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ast = root["ast"] else {
            throw InfluxError.malformedResponse(InfluxResponseDecoder.preview(of: data))
        }
        var walker = Walker()
        walker.collectImports(ast)
        walker.walk(ast, asMemberObject: false)
        return FluxScriptReading(
            writes: walker.writes || walker.unknownImport || walker.packageEscapes,
            reachesOutside: walker.unknownImport || walker.packageEscapes || walker.outsideArgument
        )
    }

    private struct Walker {
        var packages: Set<String> = []
        var unknownImport = false
        var packageEscapes = false
        var outsideArgument = false
        var writes = false

        mutating func collectImports(_ node: Any) {
            if let object = node as? [String: Any] {
                if object["type"] as? String == "ImportDeclaration" {
                    let path = (object["path"] as? [String: Any])?["value"] as? String ?? ""
                    let alias = (object["as"] as? [String: Any])?["name"] as? String
                    packages.insert(alias ?? String(path.split(separator: "/").last ?? Substring(path)))
                    if !FluxScriptReading.readOnlyPackages.contains(path) { unknownImport = true }
                    return
                }
                object.values.forEach { collectImports($0) }
            } else if let array = node as? [Any] {
                array.forEach { collectImports($0) }
            }
        }

        mutating func walk(_ node: Any?, asMemberObject: Bool) {
            if let array = node as? [Any] {
                array.forEach { walk($0, asMemberObject: false) }
                return
            }
            guard let object = node as? [String: Any] else { return }
            switch object["type"] as? String {
            case "ImportDeclaration":
                return
            case "Identifier":
                let name = object["name"] as? String ?? ""
                if FluxScriptReading.writingNames.contains(name) { writes = true }
                if packages.contains(name), !asMemberObject { packageEscapes = true }
            case "MemberExpression":
                let target = object["object"] as? [String: Any]
                let property = object["property"] as? [String: Any]
                let isPackage = target?["type"] as? String == "Identifier" && packages.contains(target?["name"] as? String ?? "")
                if isPackage, property?["type"] as? String != "Identifier" { packageEscapes = true }
                walk(target, asMemberObject: true)
                let member = property?["name"] as? String ?? property?["value"] as? String ?? ""
                if FluxScriptReading.writingNames.contains(member) { writes = true }
                if property?["type"] as? String != "Identifier", property?["type"] as? String != "StringLiteral" {
                    walk(property, asMemberObject: false)
                }
            case "Property":
                let key = object["key"] as? [String: Any]
                if let value = object["value"], !(value is NSNull) {
                    walk(value, asMemberObject: false)
                } else {
                    walk(key, asMemberObject: false)
                }
            case "CallExpression":
                for argument in object["arguments"] as? [[String: Any]] ?? [] {
                    for property in argument["properties"] as? [[String: Any]] ?? [] {
                        let key = property["key"] as? [String: Any]
                        let name = key?["name"] as? String ?? key?["value"] as? String ?? ""
                        if FluxScriptReading.outsideLabels.contains(name) { outsideArgument = true }
                    }
                }
                for (key, value) in object where key != "type" {
                    walk(value, asMemberObject: false)
                }
            default:
                for (key, value) in object where key != "type" {
                    walk(value, asMemberObject: false)
                }
            }
        }
    }
}
