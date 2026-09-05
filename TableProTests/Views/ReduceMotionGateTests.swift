//
//  ReduceMotionGateTests.swift
//  TableProTests
//
//  Reduce Motion is a system accessibility setting, and `withAnimation` captures its animation at
//  the call, so a call site that does not read the setting animates regardless of it. `withMotion`
//  is the gate. The data grid already gated its row insert and remove through `rowAnimation`, which
//  is what makes the six that did not a slip rather than a decision: two jump host removals, and
//  both copy confirmations in the plan view and the structure editor.
//

import Foundation
import Testing

@Suite("Reduce Motion gate")
struct ReduceMotionGateTests {
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    @Test("Every animated call site reads the Reduce Motion setting")
    func animationsAreGated() throws {
        let appRoot = Self.repositoryRoot.appendingPathComponent("TablePro")
        let enumerator = try #require(
            FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil)
        )

        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            /// The gate itself is the one place allowed to call the ungated function.
            guard url.lastPathComponent != "MotionAccessibility.swift" else { continue }
            offenders += Self.offenders(in: url, root: Self.repositoryRoot)
        }

        #expect(
            offenders.isEmpty,
            "These call sites animate against Reduce Motion, use withMotion: \(offenders.sorted())"
        )
    }

    private static func offenders(in url: URL, root: URL) -> [String] {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")

        var offenders: [String] = []
        for (index, line) in source.components(separatedBy: .newlines).enumerated() {
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
            var searchStart = line.startIndex
            while let found = line.range(of: "withAnimation", range: searchStart ..< line.endIndex) {
                searchStart = found.upperBound
                let rest = line[found.upperBound...]
                /// `NSTableView.insertRows(at:withAnimation:)` spells its parameter the same way and
                /// gates separately, and `withAnimation(nil)` is already the reduced behaviour.
                guard !rest.hasPrefix(":"), !rest.hasPrefix("(nil)") else { continue }
                offenders.append("\(relativePath):\(index + 1)")
            }
        }
        return offenders
    }
}
