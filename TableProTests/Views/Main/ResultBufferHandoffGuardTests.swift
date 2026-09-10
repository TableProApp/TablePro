//
//  ResultBufferHandoffGuardTests.swift
//  TableProTests
//
//  The shared row buffer holds the active result's rows and is the only copy that Fetch All, Load
//  More and cell edits write to. Anything that replaces a tab's results has to hand it back to the
//  result that owns it first, or a pinned result silently loses rows it fetched. The flush was
//  added to two of the five replacement sites and missed the other three, which is the kind of
//  omission no behavioural test catches (#2243).
//
//  The rule is per file, so it catches a replacement added where nothing flushes at all. A second
//  unflushed call inside a file that already flushes elsewhere still needs a reader.
//

import Foundation
import Testing

@testable import TablePro

@Suite("Result buffer handoff guard")
struct ResultBufferHandoffGuardTests {
    @Test("Every file that replaces a tab's results also hands the row buffer back")
    func replacementSitesFlushTheBuffer() throws {
        let offenders = try Self.filesCalling("replaceUnpinnedResults(")
            .subtracting(Self.filesCalling("flushBufferToActiveResult("))

        #expect(
            offenders.isEmpty,
            """
            Replacing a tab's results drops whatever the buffer held for the outgoing result. Call \
            flushBufferToActiveResult(tabId:pinnedOnly:) before the replacement, and \
            seedBufferFromActiveResult(tabId:) after it: \(offenders.sorted())
            """
        )
    }

    private static func filesCalling(_ call: String) throws -> Set<String> {
        let root = try repoRoot().appendingPathComponent("TablePro")
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        var files: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let callSites = text.components(separatedBy: .newlines).filter {
                $0.contains(call) && !$0.contains("func ") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///")
            }
            if !callSites.isEmpty { files.insert(url.lastPathComponent) }
        }
        return files
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
