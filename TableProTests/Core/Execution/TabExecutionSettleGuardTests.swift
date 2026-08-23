//
//  TabExecutionSettleGuardTests.swift
//  TableProTests
//
//  `settle` answers whether the claim still owned the tab, and the answer is the caller's authority
//  to write. Discarding it is the whole bug: the callers that did went on to ask `isCurrent`, which
//  settling had already made false, so their writes never ran. The compiler only warns about an
//  unused result, and this trap has been walked into three times (#2055, #2068, #2120), so it is
//  worth failing the build over.
//
//  The scan is keyed on the receiver, not on the bare method name: `MCPHandlerOutcomeGate.settle`
//  is an unrelated resume-once continuation that returns nothing, so there is no answer to consume
//  there. `registryIsOnlyReachedThroughTheScannedPropertyName` keeps that narrowing fail-closed.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Execution claim settle guard")
struct TabExecutionSettleGuardTests {
    @Test("Every settle call consumes the ownership answer it returns")
    func noSettleCallDiscardsItsAnswer() throws {
        let offenders = try Self.settleCallSites().filter { !$0.consumesResult }
        #expect(
            offenders.isEmpty,
            """
            Settling reports whether the claim still owned the tab. Write \
            `guard tabExecution.settle(claim) else { return }` and put every write below it: \
            \(offenders.map(\.description).sorted())
            """
        )
    }

    @Test("The registry is only reached through the property name the guard scans")
    func registryIsOnlyReachedThroughTheScannedPropertyName() throws {
        let references = try Self.registryReferences()
        #expect(!references.isEmpty)
        #expect(
            references.allSatisfy { $0.text.contains("var tabExecution") },
            """
            The settle guard scans for `tabExecution.settle(`. A registry reached under another \
            name escapes it, so widen the scan: \(references.map(\.description).sorted())
            """
        )
    }

    /// `invalidate(_ tabId:reason:)` releases whatever the tab is running now, which is right for a
    /// retarget, a close or a teardown and wrong for anything holding a claim: a cancelled execution
    /// unwinding after its successor had claimed the tab deleted the successor's entry, and the
    /// successor's own `settle` then refused the rows it had already fetched (#2342). A claim holder
    /// releases through `settle`, which answers and releases in one step.
    ///
    /// Keyed on the enclosing function declaring a `TabExecutionClaim` parameter rather than on the
    /// argument text: `TableLoadTraceToken` also carries a `tabId`, so a textual suffix would both
    /// miss `let id = claim.tabId` and flag `token.tabId`.
    @Test("No function holding a claim releases the tab by id")
    func claimHoldersDoNotInvalidateByTabId() throws {
        let offenders = try Self.invalidateCallSitesInsideClaimHolders()
        #expect(
            offenders.isEmpty,
            """
            A function that holds a TabExecutionClaim must release through \
            `guard tabExecution.settle(claim) else { return }`, not `tabExecution.invalidate(tabId:)`, \
            which releases the tab from whoever owns it now: \(offenders.map(\.description).sorted())
            """
        )
    }

    private struct CallSite {
        let file: String
        let line: Int
        let text: String

        /// A consumed answer decides something: a condition, or a binding the code goes on to read.
        /// `_ =` is not consumption, it is the discard this guard exists to catch, and a bare call
        /// is the same thing with a compiler warning nobody has to act on.
        var consumesResult: Bool {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("_ ="), !trimmed.hasPrefix("_=") else { return false }
            return trimmed.hasPrefix("guard ")
                || trimmed.hasPrefix("if ")
                || trimmed.hasPrefix("return ")
                || trimmed.hasPrefix("while ")
                || trimmed.contains(" = ")
        }

        var description: String { "\(file):\(line)" }
    }

    private static func settleCallSites() throws -> [CallSite] {
        try sourceLines(containing: "tabExecution.settle(")
    }

    /// Walks back from each `tabExecution.invalidate(` to the `func` that encloses it and reads the
    /// signature between them, so the test asks "does this function hold a claim" rather than
    /// pattern-matching the argument.
    private static func invalidateCallSitesInsideClaimHolders() throws -> [CallSite] {
        let sourceRoot = try repoRoot().appendingPathComponent("TablePro")
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        var offenders: [CallSite] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            for (offset, line) in lines.enumerated() where line.contains("tabExecution.invalidate(") {
                guard let signature = enclosingSignature(of: offset, in: lines),
                      signature.contains("TabExecutionClaim") else { continue }
                offenders.append(CallSite(file: url.lastPathComponent, line: offset + 1, text: line))
            }
        }
        return offenders
    }

    /// The declaration text from the nearest `func` above `index` up to the brace that opens its
    /// body, which is where a parameter list ends however many lines it spans.
    private static func enclosingSignature(of index: Int, in lines: [String]) -> String? {
        guard let start = (0 ... index).reversed().first(where: {
            lines[$0].trimmingCharacters(in: .whitespaces).contains("func ")
        }) else { return nil }

        var signature = ""
        for line in lines[start ... index] {
            signature += line
            if line.contains("{") { break }
        }
        return signature
    }

    private static func registryReferences() throws -> [CallSite] {
        try sourceLines(containing: "TabExecutionRegistry").filter {
            $0.file != "TabExecutionRegistry.swift"
                && !$0.text.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
    }

    private static func sourceLines(containing needle: String) throws -> [CallSite] {
        let sourceRoot = try repoRoot().appendingPathComponent("TablePro")
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        var sites: [CallSite] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (offset, line) in text.components(separatedBy: .newlines).enumerated()
                where line.contains(needle) {
                sites.append(CallSite(file: url.lastPathComponent, line: offset + 1, text: line))
            }
        }
        return sites
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
