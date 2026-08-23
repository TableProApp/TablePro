import Foundation
import TableProPluginKit

struct MongoDiagnosticsProducer: QueryDiagnosticsProducing {
    private static let maximumLength = 100_000

    func diagnostics(for text: String) -> [QueryDiagnostic] {
        let source = text as NSString
        guard source.length > 0, source.length <= Self.maximumLength else { return [] }

        let structure = QueryBracketScanner.scan(source, allowsLineComments: false)

        if let range = structure.unmatchedClose {
            return [QueryDiagnostic(range: range, message: String(localized: "No matching opening bracket"))]
        }
        if let range = structure.unterminatedComment {
            return [QueryDiagnostic(range: range, message: String(localized: "Unterminated comment"))]
        }

        guard !structure.hasUnclosedOpener, !structure.hasUnterminatedString else { return [] }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        do {
            _ = try MongoShellParser.parse(trimmed)
            return []
        } catch let error as MongoShellParseError {
            guard let message = error.errorDescription else { return [] }
            return [QueryDiagnostic(range: range(for: error, in: source), message: message)]
        } catch {
            return []
        }
    }

    private func range(for error: MongoShellParseError, in source: NSString) -> NSRange {
        if case .unsupportedMethod(let method) = error {
            let name = method.trimmingCharacters(in: CharacterSet(charactersIn: ".()"))
            let found = source.range(of: name)
            if found.location != NSNotFound { return found }
        }
        return firstStatementLine(in: source)
    }

    private func firstStatementLine(in source: NSString) -> NSRange {
        let full = NSRange(location: 0, length: source.length)
        let line = source.lineRange(for: NSRange(location: 0, length: 0))
        let trimmedLength = source.substring(with: line)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .utf16
            .count
        guard trimmedLength > 0 else { return full }
        return NSRange(location: line.location, length: min(trimmedLength, source.length - line.location))
    }
}
