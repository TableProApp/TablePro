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

    /// The scans above only prove the old flag is gone. This proves the readout the status bar
    /// draws IS the registry, so a future edit cannot satisfy both scans by wiring it to some third
    /// value.
    ///
    /// Behavioural rather than a source scan. The scan this replaces matched one call site's exact
    /// spelling, so moving the readout out of the toolbar broke it while the invariant it guards
    /// still held. `ExecutionReadout.isExecuting` is now computed from a stored registry rather
    /// than a stored `Bool`, which is what makes this assertable: reintroducing the parameter
    /// changes the memberwise initializer and this file stops compiling.
    @Test("The execution readout is a live read of the execution registry")
    func executionIndicatorReadsTheRegistry() {
        var registry = TabExecutionRegistry()
        let tab = UUID()
        let other = UUID()
        func readout(_ id: UUID) -> ExecutionReadout {
            ExecutionReadout(tabId: id, execution: registry, lastTiming: nil, onCancel: {})
        }

        let claim = registry.claim(tab)
        #expect(readout(tab).isExecuting)
        #expect(readout(other).isExecuting == false)

        /// Hoisted out of `#expect`, which evaluates its expression inside a closure that captures
        /// `registry` immutably, so a mutating call cannot go in one.
        let settled = registry.settle(claim)
        #expect(settled)
        #expect(readout(tab).isExecuting == false)

        /// Fetch All extends the result already on screen, so it registers unclaimed work rather
        /// than a claim. The readout has to count it, or Fetch All runs with no Stop button.
        let work = registry.beginUnclaimedWork(for: tab)
        #expect(readout(tab).isExecuting)
        registry.endUnclaimedWork(work, for: tab)
        #expect(readout(tab).isExecuting == false)
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
