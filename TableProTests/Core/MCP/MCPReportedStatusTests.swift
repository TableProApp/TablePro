//
//  MCPReportedStatusTests.swift
//  TableProTests
//
//  `ConnectionSession.status` still reads `.connected` for a session whose driver stopped answering,
//  because the driver handle is a handle rather than a live connection. `reportedStatus` is the one
//  answer to "can this be believed", and CLAUDE.md's invariant is that everything reporting
//  connection health goes through it. `ConnectionLivenessReportingTests` covers what the property
//  does; this covers who asks it.
//
//  The MCP surface disagreed with itself. `get_connection_status` used `reportedStatus`, while
//  `list_connections`, `open_connection_window` and the subscription visibility set used the raw
//  status, so one tool called an unreachable connection connected and another called it an error.
//

import Foundation
import Testing

@Suite("MCP connection health reporting")
struct MCPReportedStatusTests {
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    @Test("No MCP file reads a session's raw status to report health")
    func mcpReportsThroughReportedStatus() throws {
        let mcpRoot = Self.repositoryRoot.appendingPathComponent("TablePro/Core/MCP")
        let enumerator = try #require(
            FileManager.default.enumerator(at: mcpRoot, includingPropertiesForKeys: nil)
        )

        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            let relativePath = url.path
                .replacingOccurrences(of: Self.repositoryRoot.path + "/", with: "")
            for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                guard line.contains(".status.isConnected") else { continue }
                offenders.append("\(relativePath):\(index + 1)")
            }
        }

        /// A path that stops resolving would scan nothing and pass silently.
        #expect(scanned > 20, "Expected to scan the MCP sources, scanned \(scanned) files")
        #expect(
            offenders.isEmpty,
            "MCP reports connection health through reportedStatus, not status: \(offenders.sorted())"
        )
    }
}
