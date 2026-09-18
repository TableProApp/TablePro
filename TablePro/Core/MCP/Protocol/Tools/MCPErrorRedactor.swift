import Foundation

enum MCPErrorRedactor {
    static let placeholder = "[redacted]"
    static let maximumLength = 600

    private static let credentialKeys: [String] = [
        "host", "hostaddr", "hostname", "server", "port", "user", "username", "uid",
        "password", "passwd", "pwd", "dbname", "database", "initial catalog", "data source",
        "account", "token", "apikey", "api_key", "secret", "sslcert", "sslkey", "sslrootcert",
        "service_account", "connection_string", "dsn"
    ]

    private static let patterns: [String] = [
        "[A-Za-z][A-Za-z0-9+.-]*://[^\\s]*@[^\\s]*",
        "\\b\\d{1,3}(\\.\\d{1,3}){3}(:\\d{1,5})?\\b",
        "\\b[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]+)+:\\d{1,5}\\b",
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
}
