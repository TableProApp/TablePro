//
//  MQLDumpHeaderScanTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

// The header an MQL dump writes for a collection whose name holds a line terminator, as FormatPluginTests'
// MQLExportHelpersTests holds the plugin to writing it: the terminator escaped, the comment on one line.
struct MQLDumpHeaderScanTests {
    private static let headers = [
        #"// Collection: a\nb"#,
        #"// Collection: a\rb"#,
        #"// Collection: a\u000bb"#,
        #"// Collection: a\u000cb"#,
        #"// Collection: a\u0085b"#,
        #"// Collection: a\u2028b"#,
        #"// Collection: a\u2029b"#
    ]

    @Test("A dump's header comment runs no statement when the script is read back", arguments: headers)
    func headerCommentIsOneComment(header: String) {
        let statements = JavaScriptStatementScanner.executableStatements(in: "x = 1;" + header)
        #expect(statements.map(\.trimmed) == ["x = 1;"])
    }
}
