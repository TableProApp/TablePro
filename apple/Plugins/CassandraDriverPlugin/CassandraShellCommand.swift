import Foundation

// Only a whole statement counts. One that runs on into more text is refused, never sent: the app classified the text
// as this command, so running the rest would run a statement nothing checked.
enum CassandraShellCommand: Equatable, Sendable {
    case consistency(CassandraConsistencyLevel?)
    case serialConsistency(CassandraConsistencyLevel?)

    static func parse(_ statement: String) throws -> CassandraShellCommand? {
        guard var words = commandWords(of: statement) else { return nil }
        while words.last == ";" {
            words.removeLast()
        }
        if words.first?.uppercased() == "CONSISTENCY" {
            let level = try argument(
                Array(words.dropFirst()),
                command: "CONSISTENCY",
                allowed: CassandraConsistencyLevel.allCases
            )
            return .consistency(level)
        }
        let level = try argument(
            Array(words.dropFirst(2)),
            command: "SERIAL CONSISTENCY",
            allowed: CassandraConsistencyLevel.serialLevels
        )
        return .serialConsistency(level)
    }

    func apply(to consistency: inout CassandraConsistency) -> String {
        switch self {
        case .consistency(nil):
            return String(format: String(localized: "Current consistency level is %@."), consistency.level.rawValue)
        case .consistency(let level?):
            consistency.level = level
            return String(format: String(localized: "Consistency level set to %@."), level.rawValue)
        case .serialConsistency(nil):
            return String(
                format: String(localized: "Current serial consistency level is %@."),
                consistency.effectiveSerialLevel.rawValue
            )
        case .serialConsistency(let level?):
            consistency.serialLevel = level
            return String(format: String(localized: "Serial consistency level set to %@."), level.rawValue)
        }
    }

    private static func argument(
        _ words: [Substring],
        command: String,
        allowed: [CassandraConsistencyLevel]
    ) throws -> CassandraConsistencyLevel? {
        guard let word = words.first else { return nil }
        guard words.count == 1, word != ";" else {
            throw CassandraPluginError.queryFailed(String(
                format: String(localized: "%@ takes one level. End it with a semicolon before the next statement."),
                command
            ))
        }
        guard let level = CassandraConsistencyLevel(name: word), allowed.contains(level) else {
            throw CassandraPluginError.queryFailed(String(
                format: String(localized: "%1$@ is not a level %2$@ accepts. Use one of %3$@."),
                String(word),
                command,
                allowed.map(\.rawValue).joined(separator: ", ")
            ))
        }
        return level
    }

    // Returns at the first word that rules the command out, so an ordinary statement costs a few characters.
    private static func commandWords(of statement: String) -> [Substring]? {
        var words: [Substring] = []
        var index = statement.startIndex
        let end = statement.endIndex

        func starts(with prefix: String, at position: String.Index) -> Bool {
            statement[position...].hasPrefix(prefix)
        }

        while index < end {
            let character = statement[index]
            if character.isWhitespace {
                index = statement.index(after: index)
            } else if starts(with: "--", at: index) || starts(with: "//", at: index) {
                index = statement.unicodeScalars[index...].firstIndex { $0 == "\n" || $0 == "\r" } ?? end
            } else if starts(with: "/*", at: index) {
                let body = statement.index(index, offsetBy: 2)
                index = statement[body...].range(of: "*/", options: .literal)?.upperBound ?? end
            } else if character == ";" {
                words.append(statement[index...index])
                index = statement.index(after: index)
            } else {
                var wordEnd = statement.index(after: index)
                while wordEnd < end {
                    let next = statement[wordEnd]
                    if next.isWhitespace || next == ";" || starts(with: "--", at: wordEnd)
                        || starts(with: "//", at: wordEnd) || starts(with: "/*", at: wordEnd) {
                        break
                    }
                    wordEnd = statement.index(after: wordEnd)
                }
                words.append(statement[index..<wordEnd])
                index = wordEnd
            }

            guard isCommandSoFar(words) else { return nil }
            // Past the command and its one level the statement is refused whatever follows.
            if words.filter({ $0 != ";" }).count > 3 { break }
        }
        return isCommand(words) ? words : nil
    }

    private static func isCommandSoFar(_ words: [Substring]) -> Bool {
        guard let first = words.first?.uppercased() else { return true }
        if first == "CONSISTENCY" { return true }
        guard first == "SERIAL" else { return false }
        guard words.count >= 2 else { return true }
        return words[1].uppercased() == "CONSISTENCY"
    }

    private static func isCommand(_ words: [Substring]) -> Bool {
        guard let first = words.first?.uppercased() else { return false }
        if first == "CONSISTENCY" { return true }
        return first == "SERIAL" && words.count >= 2 && words[1].uppercased() == "CONSISTENCY"
    }
}
