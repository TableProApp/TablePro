import Foundation

// Expands the catalog's `~` and `${VAR:-default}`; an empty variable takes the default, as in a POSIX shell.
public enum MCPPathExpander {
    public static func expand(_ path: String, home: String, environment: [String: String]) -> String {
        var result = ""
        var rest = Substring(path)
        while let open = rest.range(of: "${"), let close = rest[open.upperBound...].firstIndex(of: "}") {
            result += rest[..<open.lowerBound]
            let body = rest[open.upperBound..<close]
            let name: Substring
            let fallback: Substring?
            if let separator = body.range(of: ":-") {
                name = body[..<separator.lowerBound]
                fallback = body[separator.upperBound...]
            } else {
                name = body
                fallback = nil
            }
            if let value = environment[String(name)], !value.isEmpty {
                result += value
            } else {
                result += fallback ?? ""
            }
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return expandingTilde(result, home: home)
    }

    private static func expandingTilde(_ path: String, home: String) -> String {
        let trimmedHome = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == "~" {
            return trimmedHome
        }
        if path.hasPrefix("~/") {
            return trimmedHome + path.dropFirst()
        }
        return path
    }
}
