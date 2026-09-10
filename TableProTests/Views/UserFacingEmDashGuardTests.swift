//
//  UserFacingEmDashGuardTests.swift
//  TableProTests
//

import Foundation
import Testing

/// CLAUDE.md's writing style bans the em dash from anything a user reads, and a review only catches
/// it when someone happens to look at the right line. Five had accumulated in shipped UI strings,
/// including two window titles, so this reads the source instead.
///
/// Two uses are deliberate and stay. A quoted em dash on its own is the macOS convention for "no
/// value", the one Finder and Activity Monitor use in list columns, and it is a glyph rather than a
/// sentence to rewrite. Log messages are not user-facing. The JetBrains keychain service names need
/// no exemption: they spell the character `\u{2014}`, so the literal never appears in the source.
@Suite("User-facing strings carry no em dash")
struct UserFacingEmDashGuardTests {
    private static let emDash: Character = "\u{2014}"
    private static let placeholderGlyph = "\"\u{2014}\""

    @Test("No em dash reaches a string literal in the app target")
    func appTargetStringLiteralsAreClean() throws {
        let offenders = try Self.offenders()

        #expect(
            offenders.isEmpty,
            """
            An em dash reached a user-facing string. Use a comma, period, colon, or rewrite it. \
            The house style is the comma; see "Truncated, read only" and "License expired, sync paused".
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    private static func offenders() throws -> [String] {
        let root = try repoRoot().appendingPathComponent("TablePro", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw GuardError.sourceTreeNotFound
        }

        var found: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.components(separatedBy: .newlines)
            var previous = ""
            for (index, line) in lines.enumerated() {
                defer { if !line.trimmingCharacters(in: .whitespaces).isEmpty { previous = line } }
                guard carriesProseEmDash(line: line, previous: previous) else { continue }
                found.append("\(url.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return found.sorted()
    }

    /// A line offends when an em dash survives inside a double-quoted span after the placeholder
    /// glyph is removed, and neither it nor the call it continues is a comment or a log message.
    static func carriesProseEmDash(line: String, previous: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("//") else { return false }
        guard !isLogging(trimmed), !isLogging(previous.trimmingCharacters(in: .whitespaces)) else { return false }

        let withoutPlaceholders = trimmed.replacingOccurrences(of: placeholderGlyph, with: "")
        guard withoutPlaceholders.contains(emDash) else { return false }
        return quotedSpansContainEmDash(withoutPlaceholders)
    }

    private static func isLogging(_ line: String) -> Bool {
        let markers = ["logger.", "Logger(", "os_log", ".debug(", ".info(", ".notice(", ".warning(", ".fault("]
        return markers.contains { line.contains($0) }
    }

    private static func quotedSpansContainEmDash(_ line: String) -> Bool {
        var insideQuotes = false
        var escaped = false
        for character in line {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "\"" {
                insideQuotes.toggle()
                continue
            }
            if insideQuotes, character == emDash {
                return true
            }
        }
        return false
    }

    private static func repoRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 12 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("TablePro.xcodeproj").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw GuardError.repoRootNotFound
    }

    private enum GuardError: Error {
        case repoRootNotFound
        case sourceTreeNotFound
    }
}

@Suite("Em dash guard classifies lines correctly")
struct UserFacingEmDashClassifierTests {
    private func offends(_ line: String, previous: String = "") -> Bool {
        UserFacingEmDashGuardTests.carriesProseEmDash(line: line, previous: previous)
    }

    @Test("Prose inside a string literal offends")
    func proseOffends() {
        #expect(offends("Text(\"NULL \u{2014} no referenced row\")"))
        #expect(offends("window.title = String(format: String(localized: \"PHP \u{2014} %@\"), name)"))
    }

    @Test("The no-value placeholder glyph is allowed")
    func placeholderGlyphIsAllowed() {
        #expect(!offends("Text(verbatim: \"\u{2014}\").foregroundStyle(.tertiary)"))
        #expect(!offends("guard let bytes else { return \"\u{2014}\" }"))
    }

    @Test("Comments and log messages are out of scope")
    func commentsAndLogsAreAllowed() {
        #expect(!offends("// counts newlines \u{2014} uses a fast NSString search"))
        #expect(!offends("/// Returns nil when absent \u{2014} the caller retries"))
        #expect(!offends("logger.warning(\"failed \u{2014} \\(error)\")"))
        #expect(!offends("\"Startup failed: \\(statement) \u{2014} \\(error)\"", previous: "Self.startupLogger.warning("))
    }

    @Test("An em dash outside any quoted span is not a string literal")
    func unquotedEmDashIsIgnored() {
        #expect(!offends("let separator = someValue \u{2014} other"))
    }

    @Test("An escaped unicode spelling is not the literal character")
    func escapedSpellingIsIgnored() {
        #expect(!offends("\"IntelliJ Platform DB \\u{2014} \\(uuid)\""))
    }
}
