import Foundation

enum MCPErrorRedactor {
    static let placeholder = "[redacted]"
    static let maximumLength = 600
    // The URL pattern still costs more than linear time on a long run of scheme:// with no `@`, and only the first
    // maximumLength characters are sent, so the patterns read no further than this.
    static let scannedLength = 8_192

    private static let credentialKeys: [String] = [
        "host", "hostaddr", "hostname", "server", "port", "user", "username", "uid",
        "password", "passwd", "pwd", "dbname", "database", "initial catalog", "data source",
        "account", "token", "apikey", "api_key", "secret", "sslcert", "sslkey", "sslrootcert",
        "service_account", "connection_string", "dsn"
    ]

    // The DSN and host:port patterns start only where a run of their characters starts, and never give characters
    // back: unanchored, each position inside a long run rescanned the rest of it, and a 200 KB error took minutes.
    private static let patterns: [String] = [
        "(?<![A-Za-z0-9+.-])[0-9+.-]*+[A-Za-z][A-Za-z0-9+.-]*+://[^\\s]*@[^\\s]*",
        "\\b\\d{1,3}(\\.\\d{1,3}){3}(:\\d{1,5})?\\b",
        "(?<![A-Za-z0-9_-])(?<![A-Za-z0-9_-]\\.)[A-Za-z0-9_-]++(?:\\.[A-Za-z0-9_-]++)++:\\d{1,5}\\b",
        "/(?:Users|home|var|private|tmp)/[^\\s\"']+"
    ]

    private static let compiled: [NSRegularExpression] = {
        var expressions: [NSRegularExpression] = []
        for key in credentialKeys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            if let expression = try? NSRegularExpression(
                pattern: "\\b\(escaped)\\s*=\\s*[^\\s;,)]+",
                options: [.caseInsensitive]
            ) {
                expressions.append(expression)
            }
        }
        for pattern in patterns {
            if let expression = try? NSRegularExpression(pattern: pattern, options: []) {
                expressions.append(expression)
            }
        }
        return expressions
    }()

    static func message(for error: Error, secrets: [String] = []) -> String {
        if let toolError = error as? MCPToolExecutionError {
            return redact(toolError.message, secrets: secrets)
        }
        if let dataError = error as? DatabaseAccessError {
            return redact(dataError.message, secrets: secrets)
        }
        if let databaseError = error as? DatabaseError {
            return redact(databaseError.errorDescription ?? String(describing: databaseError), secrets: secrets)
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return redact(description, secrets: secrets)
        }
        return redact(String(describing: error), secrets: secrets)
    }

    static func redact(_ text: String, secrets: [String] = []) -> String {
        var output = text
        for secret in secrets where secret.count >= 3 {
            output = output.replacingOccurrences(of: secret, with: placeholder, options: [.caseInsensitive])
        }
        output = scannedPrefix(output)
        for expression in compiled {
            let range = NSRange(output.startIndex..., in: output)
            output = expression.stringByReplacingMatches(
                in: output,
                options: [],
                range: range,
                withTemplate: placeholder
            )
        }
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (output as NSString).length > maximumLength else { return output }
        return (output as NSString).substring(to: maximumLength) + "…"
    }

    // Cut at a blank, so no piece of a token is left without the rest a pattern needs to see it.
    private static func scannedPrefix(_ text: String) -> String {
        let source = text as NSString
        guard source.length > scannedLength else { return text }
        let head = source.substring(to: scannedLength) as NSString
        let blank = head.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards)
        guard blank.location != NSNotFound else { return placeholder }
        return head.substring(to: blank.location)
    }
}
