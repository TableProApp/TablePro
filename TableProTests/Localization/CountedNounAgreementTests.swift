//
//  CountedNounAgreementTests.swift
//  TableProTests
//
//  The export sheet read "3 table to export" and the result status bar "1 rows". Both wrote the count
//  in front of an `^[noun](inflect: true)` span, and automatic grammar agreement reads only the number
//  the span encloses, so the noun never changed.
//

import Foundation
import Testing

struct CountedNounAgreementTests {
    private static let english = Locale(identifier: "en_US")

    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    /// `Text` takes the attributed path, so this is what a SwiftUI label renders.
    private static func rendered(_ value: String.LocalizationValue) -> String {
        String(AttributedString(localized: value, locale: english).characters)
    }

    @Test("A count written before the inflected span does not agree with it")
    func countOutsideTheSpanStaysSingular() {
        let rendered = Self.rendered("\(3) ^[table](inflect: true) to export")

        #expect(rendered == "3 table to export", "measured as \(rendered)")
    }

    @Test("The export summary agrees with its count", arguments: [
        (1, "1 table to export", "1 row to export"),
        (3, "3 tables to export", "3 rows to export"),
    ])
    func exportSummaryAgrees(count: Int, tables: String, rows: String) {
        #expect(Self.rendered("^[\(count) table](inflect: true) to export") == tables)
        #expect(Self.rendered("^[\(count) row](inflect: true) to export") == rows)
    }

    @Test("The result status readout agrees with the total it names")
    func resultReadoutAgreesWithItsTotal() {
        #expect(Self.rendered("^[\(1) row](inflect: true)") == "1 row")
        #expect(Self.rendered("\(1)-\(1) of ~^[\(1) row](inflect: true)") == "1-1 of ~1 row")
        #expect(Self.rendered("\(1)-\(2) of ^[\(2) row](inflect: true)") == "1-2 of 2 rows")
        #expect(Self.rendered("\(1) of ^[\(1) row](inflect: true) selected") == "1 of 1 row selected")
        #expect(Self.rendered("Executed ^[\(1) statement](inflect: true)") == "Executed 1 statement")
    }

    @Test("No view writes a count in front of an inflected span")
    func noCountSitsOutsideItsSpan() throws {
        let pattern = try NSRegularExpression(pattern: #"\\\([^()]*\)\s*\^\["#)
        let roots = ["TablePro", "TableProMobile", "Plugins"]
        var offenders: [String] = []
        for root in roots {
            let directory = Self.repositoryRoot.appendingPathComponent(root)
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                for (index, line) in source.components(separatedBy: "\n").enumerated() {
                    let range = NSRange(line.startIndex..., in: line)
                    if pattern.firstMatch(in: line, range: range) != nil {
                        offenders.append("\(url.lastPathComponent):\(index + 1)")
                    }
                }
            }
        }

        #expect(
            offenders.isEmpty,
            "Move the count inside the span, ^[\\(count) noun](inflect: true), so the noun agrees: \(offenders)"
        )
    }
}
