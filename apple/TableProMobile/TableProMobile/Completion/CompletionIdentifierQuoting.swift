import Foundation
import TableProAutocomplete
import TableProModels

nonisolated enum CompletionIdentifierQuoting {
    static func quoted(_ name: String, for type: DatabaseType) -> String {
        needsQuoting(name, for: type) ? SQLBuilder.quoteIdentifier(name, for: type) : name
    }

    // An alias or a table the list does not hold comes from the statement, so its case is the one the user wrote
    // and re-quoting it for case would point at a different name on PostgreSQL and Oracle.
    static func quotedAsWritten(_ name: String, for type: DatabaseType) -> String {
        hasBareSpelling(name, for: type) ? name : SQLBuilder.quoteIdentifier(name, for: type)
    }

    static func needsQuoting(_ name: String, for type: DatabaseType) -> Bool {
        guard hasBareSpelling(name, for: type) else { return true }
        // The list is every engine's keywords together: a quoted `date` only reads noisier, a bare reserved word fails.
        if SQLKeywords.isKeyword(name) || CompletionReservedWords.contains(name, for: type) { return true }
        switch type {
        case .postgresql, .redshift:
            return name != name.lowercased()
        case .oracle:
            return name != name.uppercased()
        default:
            return false
        }
    }

    private static func hasBareSpelling(_ name: String, for type: DatabaseType) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard !scalars.isEmpty else { return false }
        if SQLBuilder.speaksMySQLDialect(type) {
            guard !scalars.allSatisfy(isDigit), !readsAsMySQLNumber(scalars) else { return false }
            return scalars.allSatisfy(isMySQLBare)
        }
        return scalars.enumerated().allSatisfy { index, scalar in
            isBare(scalar, leading: index == 0, for: type)
        }
    }

    // `1e3`, `0x1F` and `0b101` read as numbers before they read as names.
    private static func readsAsMySQLNumber(_ scalars: [Unicode.Scalar]) -> Bool {
        let digits = scalars.prefix(while: isDigit).count
        guard digits > 0, digits < scalars.count else { return false }
        let next = scalars[digits]
        if next == "e" || next == "E" { return true }
        return digits == 1 && scalars[0] == "0" && (next == "x" || next == "X" || next == "b" || next == "B")
    }

    private static func isMySQLBare(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII {
            return isASCIILetter(scalar) || isDigit(scalar) || scalar == "_" || scalar == "$"
        }
        return scalar.value <= 0xFFFF
    }

    private static func isBare(_ scalar: Unicode.Scalar, leading: Bool, for type: DatabaseType) -> Bool {
        let letter = isASCIILetter(scalar)
        let digit = isDigit(scalar)
        switch type {
        case .postgresql, .redshift:
            let unicodeLetter = letter || (!scalar.isASCII && CharacterSet.letters.contains(scalar))
            return unicodeLetter || scalar == "_" || (!leading && (digit || scalar == "$"))
        case .mssql:
            let unicodeLetter = letter || (!scalar.isASCII && CharacterSet.letters.contains(scalar))
            return unicodeLetter || scalar == "_" || (!leading && (digit || scalar == "@" || scalar == "#" || scalar == "$"))
        case .sqlite:
            return letter || scalar == "_" || !scalar.isASCII || (!leading && (digit || scalar == "$"))
        case .oracle:
            return letter || (!leading && (digit || scalar == "_" || scalar == "$" || scalar == "#"))
        default:
            return letter || scalar == "_" || (!leading && digit)
        }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value)
    }
}
