//
//  TabQueryTaskGuardTests.swift
//  TableProTests
//
//  Cancellation is per tab, and there is exactly one route to the driver's own abort. The defect
//  this keeps out is not a wrong call, it is a second route: one window-wide handle, or one more
//  place that asks the connection to cancel without saying whose work it is.
//

import Foundation
import Testing

struct TabQueryTaskGuardTests {
    /// The window's single handle is gone. A reintroduced one is the bug: every start path cancels
    /// whatever it holds, so tab B's Run kills tab A's batch and rolls it back.
    @Test("No window-wide query handle survives")
    func noWindowWideQueryHandle() throws {
        for name in ["currentQueryTask", "currentQueryTaskOwner", "cancelInFlightQueryTask"] {
            let offenders = try Self.sourceLines(containing: name)
            #expect(
                offenders.isEmpty,
                """
                One query handle per window is what made every start path a Stop. Install and retire \
                through `queryTasks`, keyed by tab: \(offenders.map(\.description).sorted())
                """
            )
        }
    }

    /// `cancelRunningQuery` names a lease owner now, and the coordinator reaches it from one place.
    /// A second call site is a second owner-scoping decision, which is how the connection-wide
    /// version spread in the first place.
    @Test("Only the owner-scoped routes ask the driver to cancel")
    func cancelRunningQueryHasOneRoutePerSubsystem() throws {
        let allowed: Set<String> = [
            "DatabaseManager+ScopedDriver.swift",
            "MainContentCoordinator+QueryTasks.swift",
            "DatabaseAccessBridge.swift",
        ]
        let offenders = try Self.sourceLines(containing: "cancelRunningQuery(")
            .filter { !allowed.contains($0.file) }
        #expect(
            offenders.isEmpty,
            """
            A cancel has to name the lease that owns the work. Route a new one through \
            `MainContentCoordinator.cancelQueryTask(for:delivery:)`: \
            \(offenders.map(\.description).sorted())
            """
        )
    }

    /// Cancelling every tab at once is a teardown, not a Stop. A Stop that reached for it would be
    /// the window-wide behaviour again under a new name.
    @Test("Every tab's task is only ever taken down by teardown")
    func removeAllIsTeardownOnly() throws {
        let allowed: Set<String> = ["MainContentCoordinator+QueryTasks.swift"]
        let offenders = try Self.sourceLines(containing: "queryTasks.removeAll")
            .filter { !allowed.contains($0.file) }
        #expect(
            offenders.isEmpty,
            """
            `cancelAllQueryTasks()` is the teardown path and the only caller: \
            \(offenders.map(\.description).sorted())
            """
        )
    }

    private struct SourceLine {
        let file: String
        let line: Int
        var description: String { "\(file):\(line)" }
    }

    private static func sourceLines(containing needle: String) throws -> [SourceLine] {
        let sourceRoot = try repoRoot().appendingPathComponent("TablePro")
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        var sites: [SourceLine] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (offset, line) in text.components(separatedBy: .newlines).enumerated()
                where line.contains(needle) {
                sites.append(SourceLine(file: url.lastPathComponent, line: offset + 1))
            }
        }
        return sites
    }

    private static func repoRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 12 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.yml").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
