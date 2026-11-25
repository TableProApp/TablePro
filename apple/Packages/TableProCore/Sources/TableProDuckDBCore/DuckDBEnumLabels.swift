import Foundation

public enum DuckDBEnumLabels {
    // DuckDB keeps a label's backslashes and blanks as written and doubles only its quotes. A LIST or ARRAY of an
    // enum, `ENUM('a')[]` or `ENUM('a')[2]`, gives its elements' labels.
    public static func labels(inType typeName: String) -> [String]? {
        guard typeName.uppercased().hasPrefix("ENUM("), let close = typeName.lastIndex(of: ")"),
              isListSuffix(typeName[typeName.index(after: close)...]) else { return nil }
        var labels: [String] = []
        var current = ""
        var inQuote = false
        var characters = typeName[typeName.index(typeName.startIndex, offsetBy: 5)..<close]
        while let character = characters.popFirst() {
            guard character == "'" else {
                if inQuote { current.append(character) }
                continue
            }
            if inQuote, characters.first == "'" {
                current.append("'")
                characters.removeFirst()
            } else if inQuote {
                labels.append(current)
                current = ""
                inQuote = false
            } else {
                inQuote = true
            }
        }
        return labels.isEmpty ? nil : labels
    }

    private static func isListSuffix(_ suffix: Substring) -> Bool {
        var rest = suffix
        while !rest.isEmpty {
            guard rest.first == "[", let end = rest.firstIndex(of: "]") else { return false }
            guard rest[rest.index(after: rest.startIndex)..<end].allSatisfy({ ("0"..."9").contains($0) }) else {
                return false
            }
            rest = rest[rest.index(after: end)...]
        }
        return true
    }
}
