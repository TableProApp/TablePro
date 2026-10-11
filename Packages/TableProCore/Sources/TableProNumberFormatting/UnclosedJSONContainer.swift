internal struct UnclosedJSONContainer {
    private enum Container {
        case array
        case object
    }

    private enum Expectation {
        case value
        case valueOrClose
        case key
        case keyOrClose
        case colon
        case separatorOrClose
        case nothing
    }

    private enum Lexeme {
        case structure
        case string
        case escape
        case unicodeEscape(remainingDigits: Int)
        case bareWord
    }

    private static let simpleEscapes: Set<Unicode.Scalar> = ["\"", "\\", "/", "b", "f", "n", "r", "t"]
    private static let whitespace: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r"]
    private static let bareWordSymbols: Set<Unicode.Scalar> = ["+", "-", "."]

    private var containers: [Container] = []
    private var expectation = Expectation.value
    private var lexeme = Lexeme.structure

    internal static func isOpenedBy<Scalars: Sequence>(
        _ scalars: Scalars
    ) -> Bool where Scalars.Element == Unicode.Scalar {
        var scanner = UnclosedJSONContainer()
        for scalar in scalars {
            guard scanner.consume(scalar) else { return false }
        }
        return !scanner.containers.isEmpty
    }

    private mutating func consume(_ scalar: Unicode.Scalar) -> Bool {
        switch lexeme {
        case .structure:
            return consumeStructure(scalar)
        case .string:
            return consumeString(scalar)
        case .escape:
            return consumeEscape(scalar)
        case .unicodeEscape(let remainingDigits):
            guard scalar.properties.isASCIIHexDigit else { return false }
            lexeme = remainingDigits > 1 ? .unicodeEscape(remainingDigits: remainingDigits - 1) : .string
            return true
        case .bareWord:
            guard !Self.isBareWordScalar(scalar) else { return true }
            lexeme = .structure
            return consumeStructure(scalar)
        }
    }

    private mutating func consumeString(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "\"":
            lexeme = .structure
        case "\\":
            lexeme = .escape
        default:
            return scalar.value >= 0x20
        }
        return true
    }

    private mutating func consumeEscape(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "u" {
            lexeme = .unicodeEscape(remainingDigits: 4)
            return true
        }
        guard Self.simpleEscapes.contains(scalar) else { return false }
        lexeme = .string
        return true
    }

    private mutating func consumeStructure(_ scalar: Unicode.Scalar) -> Bool {
        guard !Self.whitespace.contains(scalar) else { return true }
        switch expectation {
        case .value:
            return openValue(scalar)
        case .valueOrClose:
            return scalar == "]" ? close(.array) : openValue(scalar)
        case .key:
            return openKey(scalar)
        case .keyOrClose:
            return scalar == "}" ? close(.object) : openKey(scalar)
        case .colon:
            guard scalar == ":" else { return false }
            expectation = .value
            return true
        case .separatorOrClose:
            return separateOrClose(scalar)
        case .nothing:
            return false
        }
    }

    private mutating func openValue(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "[":
            containers.append(.array)
            expectation = .valueOrClose
        case "{":
            containers.append(.object)
            expectation = .keyOrClose
        case "\"":
            lexeme = .string
            expectation = expectationAfterValue
        default:
            guard Self.isBareWordScalar(scalar) else { return false }
            lexeme = .bareWord
            expectation = expectationAfterValue
        }
        return true
    }

    private mutating func openKey(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar == "\"" else { return false }
        lexeme = .string
        expectation = .colon
        return true
    }

    private mutating func separateOrClose(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case ",":
            expectation = containers.last == .object ? .key : .value
            return true
        case "]":
            return close(.array)
        case "}":
            return close(.object)
        default:
            return false
        }
    }

    private mutating func close(_ container: Container) -> Bool {
        guard containers.last == container else { return false }
        containers.removeLast()
        expectation = expectationAfterValue
        return true
    }

    private var expectationAfterValue: Expectation {
        containers.isEmpty ? .nothing : .separatorOrClose
    }

    private static func isBareWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else { return false }
        return scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || bareWordSymbols.contains(scalar)
    }
}
