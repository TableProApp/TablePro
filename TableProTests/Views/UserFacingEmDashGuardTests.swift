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
struct UserFacingEmDashGuardTests {
    private static let emDash: Character = "\u{2014}"
    private static let placeholderGlyph = "\"\u{2014}\""

    @Test("No em dash reaches a string literal in the app target")
    func appTargetStringLiteralsAreClean() throws {
        let (scanned, offenders) = try UserFacingSourceScan.scanAppTarget(offends: Self.carriesProseEmDash)

        #expect(scanned > 500, "Expected to scan the app target, scanned \(scanned) files")
        #expect(
            offenders.isEmpty,
            """
            An em dash reached a user-facing string. Use a comma, period, colon, or rewrite it. \
            The house style is the comma; see "Truncated, read only" and "License expired, sync paused".
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    static func carriesProseEmDash(line: String, previous: String) -> Bool {
        guard let code = UserFacingSourceScan.userFacingCode(line: line, previous: previous) else { return false }
        return quotedSpansContainEmDash(code.replacingOccurrences(of: placeholderGlyph, with: ""))
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
}

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
        #expect(!offends("lifecycleLogger.error(\"failed \u{2014} \\(error)\")"))
        #expect(!offends(".error(\"a \u{2014} b\")", previous: "Logger(subsystem: \"com.TablePro\", category: \"Driver\")"))
        #expect(!offends("let detail = parts.joined(separator: \", \") // was \"a \u{2014} b\""))
    }

    @Test("A finished log call does not cover the line after it")
    func lineAfterLogCallOffends() {
        #expect(offends("return \"A \u{2014} B\"", previous: "Self.logger.info(\"Loaded\")"))
        #expect(offends("Text(\"A \u{2014} B\")", previous: "let info = ConnectionFailureClassifier.info(for: error)"))
    }

    @Test("A call named like a log level is user-facing")
    func logLevelLookalikesOffend() {
        #expect(offends("let info = ConnectionFailureClassifier.info(for: error, hint: \"A \u{2014} B\")"))
        #expect(offends("banners.append(.notice(String(localized: \"A \u{2014} B\")))"))
        #expect(offends("return .warning(String(localized: \"A \u{2014} B\"))"))
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
