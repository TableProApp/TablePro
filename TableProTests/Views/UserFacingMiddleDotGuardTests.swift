//
//  UserFacingMiddleDotGuardTests.swift
//  TableProTests
//

import Foundation
import Testing

/// The escaped spelling draws the same separator as the character, so both are banned.
struct UserFacingMiddleDotGuardTests {
    static let middleDot: Character = "\u{00B7}"

    @Test("No middle dot reaches a string literal in the app target")
    func appTargetStringLiteralsAreClean() throws {
        let (scanned, offenders) = try UserFacingSourceScan.scanAppTarget(offends: Self.carriesMiddleDot)

        #expect(scanned > 500, "Expected to scan the app target, scanned \(scanned) files")
        #expect(
            offenders.isEmpty,
            """
            A middle dot reached a user-facing string. Join facts with ", ", put a qualifier in \
            parentheses, or lay the parts out as separate labels.
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// Any code on the line counts, not only a quoted span, so a multi-line string literal is covered.
    static func carriesMiddleDot(line: String, previous: String) -> Bool {
        guard let code = UserFacingSourceScan.userFacingCode(line: line, previous: previous) else { return false }
        if code.contains(middleDot) { return true }
        return code.range(of: #"\\u\{0*b7\}"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

struct UserFacingMiddleDotClassifierTests {
    private func offends(_ line: String, previous: String = "") -> Bool {
        UserFacingMiddleDotGuardTests.carriesMiddleDot(line: line, previous: previous)
    }

    @Test("A middle dot inside a string literal offends")
    func literalOffends() {
        #expect(offends("Text(\"v\\(version) \u{00B7} \\(source)\")"))
        #expect(offends(".joined(separator: \" \u{00B7} \")"))
        #expect(offends("Text(\"\u{00B7}\")"))
    }

    @Test("The escaped spelling offends in any case and padding")
    func escapedSpellingOffends() {
        #expect(offends(".joined(separator: \" \\u{00B7} \")"))
        #expect(offends(".joined(separator: \" \\u{b7} \")"))
        #expect(offends(".joined(separator: \" \\u{00b7} \")"))
    }

    @Test("The body of a multi-line string literal is covered")
    func multilineBodyOffends() {
        #expect(offends("    Ran 5 times \u{00B7} avg 12 ms"))
    }

    @Test("Comments and log messages are out of scope")
    func commentsAndLogsAreAllowed() {
        #expect(!offends("// Build detail string: \"PK \u{00B7} NOT NULL\""))
        #expect(!offends("/// Shipped as \"Team \u{00B7} Lifetime\""))
        #expect(!offends("let detail = parts.joined(separator: \", \") // was \u{00B7}"))
        #expect(!offends("logger.debug(\"loaded \\(count) \u{00B7} \\(name)\")"))
        #expect(!offends("\"\\(table) \u{00B7} \\(error)\"", previous: "Self.logger.warning("))
        #expect(!offends("lifecycleLogger.error(\"failed \u{00B7} \\(error)\")"))
        #expect(!offends(".debug(\"a \u{00B7} b\")", previous: "Logger(subsystem: \"com.TablePro\", category: \"Driver\")"))
    }

    @Test("A finished log call does not cover the line after it")
    func lineAfterLogCallOffends() {
        #expect(offends("return parts.joined(separator: \" \u{00B7} \")", previous: "Self.logger.info(\"Loaded\")"))
        #expect(offends("\"A \u{00B7} B\"", previous: "let info = ConnectionFailureClassifier.info(for: error)"))
    }

    @Test("A banner case named like a log level is user-facing")
    func logLevelLookalikesOffend() {
        #expect(offends("banners.append(.notice(String(localized: \"A \u{00B7} B\")))"))
        #expect(offends("return .warning(String(localized: \"A \u{00B7} B\"))"))
    }

    @Test("A comma, a URL and other escapes are not middle dots")
    func lookalikesAreIgnored() {
        #expect(!offends(".joined(separator: \", \")"))
        #expect(!offends("let url = \"https://tablepro.app/docs\""))
        #expect(!offends("let bullet = \"\\u{2022}\""))
        #expect(!offends("let point = \"\\u{B70}\""))
    }
}
