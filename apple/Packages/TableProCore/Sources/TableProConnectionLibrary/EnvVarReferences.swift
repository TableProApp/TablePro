import Foundation

public enum EnvVarReferences {
    private static let pattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)"#
    )

    public static func names(in text: String) -> Set<String> {
        Set(references(in: text).map(\.name))
    }

    public static func replacing(in text: String, using lookup: (String) -> String?) -> String {
        let found = references(in: text)
        guard !found.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for reference in found.reversed() {
            if let value = lookup(reference.name) {
                result.replaceCharacters(in: reference.range, with: value)
            }
        }
        return result as String
    }

    private static func references(in text: String) -> [(name: String, range: NSRange)] {
        let source = text as NSString
        guard source.length > 0, let pattern else { return [] }
        return pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            let braced = match.range(at: 1)
            let nameRange = braced.location != NSNotFound ? braced : match.range(at: 2)
            return (source.substring(with: nameRange), match.range)
        }
    }
}
