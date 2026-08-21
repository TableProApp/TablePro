//
//  WindowBusyStateGuardTests.swift
//  TableProTests
//
//  "Executing…" and the Stop control beside it are a function of `TabExecutionRegistry`, and of
//  nothing else. They used to be a stored bool on `ConnectionToolbarState`, raised and lowered by
//  hand beside each execution and released only behind two ownership checks, so any path that ended
//  an execution without satisfying both left the titlebar, Stop, `Cmd+.` and the disconnect warning
//  describing work that was over. The only way back was pressing Stop (#2342, and #548 before it).
//
//  A second copy of that answer cannot come back quietly, so the build fails on one.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Window busy state guard")
struct WindowBusyStateGuardTests {
    @Test("Nothing stores or writes a second copy of whether the window is busy")
    func noStoredWindowExecutionFlag() throws {
        let offenders = try Self.sourceLines { line in
            line.contains("setExecuting(") || line.contains("toolbarState.isExecuting")
        }
        #expect(
            offenders.isEmpty,
            """
            Whether anything is running is derived from `tabExecution.isAnyExecuting`. A stored copy \
            desynchronizes the moment one path ends an execution without lowering it: \
            \(offenders.map(\.description).sorted())
            """
        )
    }

    @Test("The toolbar state holds no execution flag of its own")
    func toolbarStateHoldsNoExecutionFlag() throws {
        let offenders = try Self.sourceLines(in: "ConnectionToolbarState.swift") { line in
            line.contains("isExecuting") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("///")
        }
        #expect(
            offenders.isEmpty,
            """
            `ConnectionToolbarState` owns the connection's state. Whether a query is running belongs \
            to `TabExecutionRegistry`: \(offenders.map(\.description).sorted())
            """
        )
    }

    /// The scan above only proves the old flag is gone. This proves the indicator reads the registry,
    /// so a future edit cannot satisfy both scans by wiring the toolbar to some third value.
    @Test("The execution indicator is fed from the execution registry")
    func executionIndicatorReadsTheRegistry() throws {
        let callSites = try Self.sourceLines { $0.contains("isExecuting: coordinator?.tabExecution.isAnyExecuting") }
        #expect(callSites.count == 1)
    }

    private struct SourceLine {
        let file: String
        let line: Int

        var description: String { "\(file):\(line)" }
    }

    private static func sourceLines(
        in fileName: String? = nil,
        matching predicate: (String) -> Bool
    ) throws -> [SourceLine] {
        let sourceRoot = try repoRoot().appendingPathComponent("TablePro")
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        var matches: [SourceLine] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            if let fileName, url.lastPathComponent != fileName { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (offset, line) in text.components(separatedBy: .newlines).enumerated() where predicate(line) {
                matches.append(SourceLine(file: url.lastPathComponent, line: offset + 1))
            }
        }
        return matches
    }

    private static func repoRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 12 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("TablePro.xcodeproj").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
