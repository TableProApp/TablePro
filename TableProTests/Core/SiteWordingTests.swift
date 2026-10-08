//
//  SiteWordingTests.swift
//  TableProTests
//
//  tablepro.app sells Starter and Team, billed Monthly, Yearly or One-time, and its privacy policy
//  says the server stores each usage report with its IP address and can link it to a license. The
//  app asked for a "Pro license", a plan the pricing page does not have, and called the report
//  anonymous.
//

import Foundation
import Testing

struct SiteWordingTests {
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    /// Comments are dropped before the scan, because a comment may name what was removed.
    private static func code(of source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func appCode(matching pattern: String) throws -> (files: Int, hits: [String]) {
        let expression = try NSRegularExpression(pattern: pattern)
        let appRoot = repositoryRoot.appendingPathComponent("TablePro")
        let enumerator = try #require(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))

        var files = 0
        var hits: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files += 1
            let text = Self.code(of: try String(contentsOf: url, encoding: .utf8)) as NSString
            hits += expression
                .matches(in: text as String, range: NSRange(location: 0, length: text.length))
                .map { "\(url.lastPathComponent): \(text.substring(with: $0.range))" }
        }
        return (files, hits)
    }

    @Test("No string names a plan or a billing cycle the pricing page does not sell")
    func plansAreStarterAndTeam() throws {
        let scan = try Self.appCode(matching: #"(?<![A-Za-z])Pro (license|features?|plan)|"(Pro|PRO|Lifetime)""#)

        /// Guards the scan itself: a root that stopped resolving reads as a clean run.
        #expect(scan.files > 1_000, "Expected to scan the app sources, found \(scan.files) files")
        #expect(scan.hits.isEmpty, "Name the plan a feature needs, Starter or Team: \(scan.hits)")
    }

    @Test("No string calls the usage report anonymous")
    func usageReportIsNotCalledAnonymous() throws {
        let scan = try Self.appCode(matching: "(?i)anonymous (usage|statistics|analytics|report|heartbeat)")

        #expect(scan.files > 1_000, "Expected to scan the app sources, found \(scan.files) files")
        #expect(scan.hits.isEmpty, "The report carries a hashed machine ID: \(scan.hits)")
    }
}
