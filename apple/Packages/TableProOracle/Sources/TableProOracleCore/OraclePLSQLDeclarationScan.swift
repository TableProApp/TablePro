import Foundation

// DBMS_DEBUG has no call that lists a frame's variables; GET_VALUE takes a name. The names come from the unit's
// ALL_SOURCE text: PL/Scope would give exact declarations, but only for units compiled with PLSCOPE_SETTINGS
// 'IDENTIFIERS:ALL' (the default is NONE, and the compile for debug keeps the unit's settings), and on 26ai its
// USAGE_CONTEXT_ID came back 0 for every row, so scopes would still be guessed from lines. A name this scan offers
// that is not in scope comes back from GET_VALUE as no_such_object and is dropped, so the server decides scope.
public struct OraclePLSQLDeclarationScan: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case parameter
        case variable
        case constant
        case iterator
    }

    public struct Declaration: Sendable, Equatable {
        public let name: String
        public let typeText: String?
        public let line: Int
        public let kind: Kind
        // Nil for a package-level variable.
        public let subprogram: Int?
    }

    public struct Subprogram: Sendable, Equatable {
        public let name: String
        public let headerLine: Int
        public internal(set) var endLine: Int?
        public let parent: Int?
        public internal(set) var isDefinition: Bool

        public var depth: Int = 1
    }

    public private(set) var declarations: [Declaration] = []
    public private(set) var subprograms: [Subprogram] = []

    public init(source: String) {
        var parser = Parser(tokens: Lexer.tokens(of: source))
        parser.run()
        declarations = parser.declarations.filter { declaration in
            guard let index = declaration.subprogram else { return true }
            return parser.subprograms[index].isDefinition
        }
        subprograms = parser.subprograms
    }

    // The header lines of the unit-level subprograms named `name`: every overload, since the first one entered is the
    // one the debugger called.
    public func headerLines(ofSubprogramNamed name: String) -> [Int] {
        subprograms.filter { $0.isDefinition && $0.depth == 1 && $0.name == name }.map(\.headerLine)
    }

    public func innermostSubprogram(containing line: Int) -> Int? {
        var best: Int?
        for (index, subprogram) in subprograms.enumerated() where subprogram.isDefinition {
            guard subprogram.headerLine <= line, line <= (subprogram.endLine ?? Int.max) else { continue }
            if let current = best, subprograms[current].headerLine > subprogram.headerLine { continue }
            best = index
        }
        return best
    }

    // Parameters and locals of the subprogram running at `line`, then of each subprogram around it.
    public func candidates(atLine line: Int) -> [Declaration] {
        guard let innermost = innermostSubprogram(containing: line) else { return [] }
        var chain: [Int] = []
        var current: Int? = innermost
        while let index = current {
            chain.append(index)
            current = subprograms[index].parent
        }
        var seen: Set<String> = []
        var result: [Declaration] = []
        for index in chain {
            // A loop index exists only inside its loop, which starts at or after its own line.
            for declaration in declarations where declaration.subprogram == index && !seen.contains(declaration.name)
                && (declaration.kind != .iterator || declaration.line <= line) {
                seen.insert(declaration.name)
                result.append(declaration)
            }
        }
        return result
    }

    public var packageVariables: [Declaration] {
        declarations.filter { $0.subprogram == nil }
    }
}

extension OraclePLSQLDeclarationScan {
    struct Token: Equatable {
        enum Kind: Equatable {
            case word
            case quoted
            case symbol
            case other
        }

        let kind: Kind
        let text: String
        let line: Int

        func isWord(_ words: String...) -> Bool {
            kind == .word && words.contains(text)
        }

        func isSymbol(_ symbol: String) -> Bool {
            kind == .symbol && text == symbol
        }

        var isName: Bool { kind == .word || kind == .quoted }
    }

    enum Lexer {
        static func tokens(of source: String) -> [Token] {
            let characters = Array(source.unicodeScalars)
            var tokens: [Token] = []
            var index = 0
            var line = 1
            func peek(_ offset: Int = 0) -> Unicode.Scalar? {
                index + offset < characters.count ? characters[index + offset] : nil
            }
            func isWordStart(_ scalar: Unicode.Scalar) -> Bool {
                scalar.properties.isAlphabetic
            }
            func isWordPart(_ scalar: Unicode.Scalar) -> Bool {
                scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "$" || scalar == "#"
            }
            func skipString(closing: Unicode.Scalar, doubled: Bool) {
                while let scalar = peek() {
                    index += 1
                    if scalar == "\n" { line += 1 }
                    if scalar == closing {
                        if doubled, peek() == closing {
                            index += 1
                            continue
                        }
                        if !doubled, peek() == "'" {
                            index += 1
                            return
                        }
                        if doubled { return }
                    }
                }
            }
            while let scalar = peek() {
                if scalar == "\n" {
                    line += 1
                    index += 1
                } else if scalar.properties.isWhitespace {
                    index += 1
                } else if scalar == "-", peek(1) == "-" {
                    while let next = peek(), next != "\n" { index += 1 }
                } else if scalar == "/", peek(1) == "*" {
                    index += 2
                    while let next = peek(), !(next == "*" && peek(1) == "/") {
                        if next == "\n" { line += 1 }
                        index += 1
                    }
                    index += 2
                } else if scalar == "'" {
                    let startLine = line
                    index += 1
                    skipString(closing: "'", doubled: true)
                    tokens.append(Token(kind: .other, text: "'", line: startLine))
                } else if scalar == "q" || scalar == "Q", peek(1) == "'", let open = peek(2) {
                    let startLine = line
                    let closing: Unicode.Scalar
                    switch open {
                    case "[": closing = "]"
                    case "{": closing = "}"
                    case "(": closing = ")"
                    case "<": closing = ">"
                    default: closing = open
                    }
                    index += 3
                    skipString(closing: closing, doubled: false)
                    tokens.append(Token(kind: .other, text: "'", line: startLine))
                } else if scalar == "\"" {
                    let startLine = line
                    index += 1
                    var text = String.UnicodeScalarView()
                    while let next = peek(), next != "\"" {
                        if next == "\n" { line += 1 }
                        text.append(next)
                        index += 1
                    }
                    index += 1
                    tokens.append(Token(kind: .quoted, text: String(text), line: startLine))
                } else if isWordStart(scalar) {
                    var text = String.UnicodeScalarView()
                    while let next = peek(), isWordPart(next) {
                        text.append(next)
                        index += 1
                    }
                    tokens.append(Token(kind: .word, text: String(text).uppercased(), line: line))
                } else if ("0"..."9").contains(scalar) {
                    var text = String.UnicodeScalarView()
                    while let next = peek(), isWordPart(next) || next == "." {
                        text.append(next)
                        index += 1
                    }
                    tokens.append(Token(kind: .other, text: String(text), line: line))
                } else if scalar == ":", peek(1) == "=" {
                    tokens.append(Token(kind: .symbol, text: ":=", line: line))
                    index += 2
                } else if scalar == "=", peek(1) == ">" {
                    tokens.append(Token(kind: .symbol, text: "=>", line: line))
                    index += 2
                } else {
                    tokens.append(Token(kind: .symbol, text: String(scalar), line: line))
                    index += 1
                }
            }
            return tokens
        }
    }

    struct Parser {
        enum Phase {
            case declare
            case body
        }

        enum Frame {
            case unit(Phase)
            case subprogram(Int, Phase)
            case block(Phase)
            case caseExpression
        }

        let tokens: [Token]
        var position = 0
        var stack: [Frame] = []
        var declarations: [Declaration] = []
        var subprograms: [Subprogram] = []

        init(tokens: [Token]) {
            self.tokens = tokens
        }

        var current: Token? { position < tokens.count ? tokens[position] : nil }

        func peekToken(at offset: Int) -> Token? {
            position + offset < tokens.count ? tokens[position + offset] : nil
        }

        var currentSubprogram: Int? {
            for frame in stack.reversed() {
                if case .subprogram(let index, _) = frame { return index }
            }
            return nil
        }

        var subprogramDepth: Int {
            stack.reduce(0) { count, frame in
                if case .subprogram = frame { return count + 1 }
                return count
            }
        }

        mutating func run() {
            readUnitHeader()
            while let token = current {
                guard let frame = stack.last else {
                    if token.isWord("PROCEDURE", "FUNCTION") {
                        readSubprogramHeader()
                    } else if token.isWord("DECLARE") {
                        stack.append(.block(.declare))
                        position += 1
                    } else if token.isWord("BEGIN") {
                        stack.append(.block(.body))
                        position += 1
                    } else {
                        position += 1
                    }
                    continue
                }
                switch frame {
                case .unit(.declare), .subprogram(_, .declare), .block(.declare):
                    readDeclaration()
                case .unit(.body), .subprogram(_, .body), .block(.body), .caseExpression:
                    readBodyToken()
                }
            }
        }

        // PACKAGE [BODY] name IS | TYPE BODY name IS | TRIGGER ... ; a standalone PROCEDURE or FUNCTION is read as
        // a subprogram.
        mutating func readUnitHeader() {
            guard let first = current else { return }
            if first.isWord("CREATE") {
                while let token = current, !token.isWord("PACKAGE", "PROCEDURE", "FUNCTION", "TYPE", "TRIGGER") {
                    position += 1
                }
            }
            guard let head = current else { return }
            if head.isWord("PACKAGE", "TYPE") {
                while let token = current, !token.isWord("IS", "AS") { position += 1 }
                position += 1
                stack.append(.unit(.declare))
            } else if head.isWord("TRIGGER") {
                while let token = current, !token.isWord("DECLARE", "BEGIN", "COMPOUND") { position += 1 }
            }
        }

        mutating func readSubprogramHeader() {
            guard let keyword = current else { return }
            position += 1
            guard let nameToken = current, nameToken.isName else { return }
            position += 1
            let index = subprograms.count
            var subprogram = Subprogram(
                name: nameToken.text,
                headerLine: keyword.line,
                endLine: nil,
                parent: currentSubprogram,
                isDefinition: false
            )
            subprogram.depth = subprogramDepth + 1
            subprograms.append(subprogram)
            if current?.isSymbol("(") == true {
                readParameters(of: index)
            }
            var depth = 0
            while let token = current {
                if token.isSymbol("(") { depth += 1 }
                if token.isSymbol(")") { depth -= 1 }
                if depth == 0, token.isSymbol(";") {
                    position += 1
                    return
                }
                if depth == 0, token.isWord("IS", "AS") {
                    position += 1
                    // `IS LANGUAGE C` / `AS EXTERNAL` bodies have no PL/SQL to step through.
                    if current?.isWord("LANGUAGE", "EXTERNAL") == true {
                        skipStatement()
                        return
                    }
                    subprograms[index].isDefinition = true
                    stack.append(.subprogram(index, .declare))
                    return
                }
                position += 1
            }
        }

        mutating func readParameters(of subprogram: Int) {
            position += 1
            var parts: [Token] = []
            var depth = 1
            while let token = current {
                position += 1
                if token.isSymbol("(") { depth += 1 }
                if token.isSymbol(")") {
                    depth -= 1
                    if depth == 0 {
                        addParameter(parts, subprogram: subprogram)
                        return
                    }
                }
                if depth == 1, token.isSymbol(",") {
                    addParameter(parts, subprogram: subprogram)
                    parts = []
                    continue
                }
                parts.append(token)
            }
        }

        mutating func addParameter(_ parts: [Token], subprogram: Int) {
            guard let name = parts.first, name.isName else { return }
            var rest = parts.dropFirst()
            while let mode = rest.first, mode.isWord("IN", "OUT", "NOCOPY") { rest = rest.dropFirst() }
            let type = rest.prefix { !$0.isSymbol(":=") && !$0.isWord("DEFAULT") }
            declarations.append(Declaration(
                name: name.text,
                typeText: Self.typeText(type),
                line: name.line,
                kind: .parameter,
                subprogram: subprogram
            ))
        }

        mutating func readDeclaration() {
            guard let token = current, let frame = stack.last else { return }
            if token.isWord("BEGIN") {
                position += 1
                switch frame {
                case .unit: replaceTop(with: .unit(.body))
                case .subprogram(let index, _): replaceTop(with: .subprogram(index, .body))
                default: replaceTop(with: .block(.body))
                }
                return
            }
            if token.isWord("END") {
                closeFrame(at: token.line)
                skipStatement()
                return
            }
            if token.isWord("PROCEDURE", "FUNCTION") {
                readSubprogramHeader()
                return
            }
            // A type body's method prefixes.
            if token.isWord("MEMBER", "STATIC", "CONSTRUCTOR", "MAP", "ORDER", "OVERRIDING", "FINAL", "INSTANTIABLE") {
                position += 1
                return
            }
            if token.isWord("TYPE", "SUBTYPE", "CURSOR", "PRAGMA") || !token.isName {
                skipStatement()
                return
            }
            position += 1
            var isConstant = false
            if current?.isWord("CONSTANT") == true {
                isConstant = true
                position += 1
            }
            if current?.isWord("EXCEPTION") == true {
                skipStatement()
                return
            }
            var typeTokens: [Token] = []
            var depth = 0
            while let next = current {
                if next.isSymbol("(") { depth += 1 }
                if next.isSymbol(")") { depth -= 1 }
                if depth == 0, next.isSymbol(";") || next.isSymbol(":=") || next.isWord("DEFAULT", "NOT") { break }
                typeTokens.append(next)
                position += 1
            }
            declarations.append(Declaration(
                name: token.text,
                typeText: Self.typeText(typeTokens[...]),
                line: token.line,
                kind: isConstant ? .constant : .variable,
                subprogram: currentSubprogram
            ))
            skipStatement()
        }

        mutating func readBodyToken() {
            guard let token = current else { return }
            position += 1
            if token.isWord("BEGIN") {
                stack.append(.block(.body))
            } else if token.isWord("DECLARE") {
                stack.append(.block(.declare))
            } else if token.isWord("CASE") {
                stack.append(.caseExpression)
            } else if token.isWord("END") {
                if current?.isWord("IF", "LOOP") == true {
                    position += 1
                } else if current?.isWord("CASE") == true {
                    position += 1
                    popCase()
                } else if case .caseExpression = stack.last {
                    stack.removeLast()
                } else {
                    closeFrame(at: token.line)
                    skipStatement()
                }
            } else if token.isWord("FOR"), let name = current, name.isName, peekToken(at: 1)?.isWord("IN") == true {
                declarations.append(Declaration(
                    name: name.text,
                    typeText: nil,
                    line: name.line,
                    kind: .iterator,
                    subprogram: currentSubprogram
                ))
            }
        }

        mutating func popCase() {
            if case .caseExpression = stack.last { stack.removeLast() }
        }

        mutating func closeFrame(at line: Int) {
            guard let frame = stack.popLast() else { return }
            if case .subprogram(let index, _) = frame {
                subprograms[index].endLine = line
            }
        }

        mutating func replaceTop(with frame: Frame) {
            stack.removeLast()
            stack.append(frame)
        }

        mutating func skipStatement() {
            var depth = 0
            while let token = current {
                position += 1
                if token.isSymbol("(") { depth += 1 }
                if token.isSymbol(")") { depth -= 1 }
                if depth <= 0, token.isSymbol(";") { return }
            }
        }

        static func typeText(_ tokens: ArraySlice<Token>) -> String? {
            var text = ""
            for token in tokens {
                let piece = token.kind == .quoted ? "\"\(token.text)\"" : token.text
                if text.isEmpty || token.isSymbol("(") || token.isSymbol(")") || token.isSymbol(",")
                    || token.isSymbol("%") || token.isSymbol(".") || text.hasSuffix("(") || text.hasSuffix("%")
                    || text.hasSuffix(".") {
                    text += piece
                } else {
                    text += " " + piece
                }
            }
            return text.isEmpty ? nil : text
        }
    }
}
