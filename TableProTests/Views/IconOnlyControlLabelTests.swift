//
//  IconOnlyControlLabelTests.swift
//  TableProTests
//
//  A control whose whole label is an SF Symbol has no name for VoiceOver to read and no tooltip for
//  a sighted user to discover it by, so the symbol name is all anyone gets. Four shipped that way:
//  the row inspector's value menu, the delete button on a custom slash command, and both month
//  chevrons in the date picker, whose own day cells were labelled correctly.
//

import Foundation
import Testing

@Suite("Icon-only control labels")
struct IconOnlyControlLabelTests {
    private static let labelMarker = "} label: {"

    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    /// Any one of these gives the control a name. `accessibilityHidden` and `accessibilityElement`
    /// count because they hand the naming to an ancestor that speaks for the whole subtree, which is
    /// what an editor tab does.
    private static let namingModifiers = [
        ".help(",
        "accessibilityLabel",
        "accessibilityHidden",
        "accessibilityElement"
    ]

    @Test("Every SwiftUI control labelled only by an SF Symbol carries a name")
    func iconOnlyControlsAreNamed() throws {
        let viewsRoot = Self.repositoryRoot.appendingPathComponent("TablePro/Views")
        let enumerator = try #require(
            FileManager.default.enumerator(at: viewsRoot, includingPropertiesForKeys: nil)
        )

        var inspected = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let result = Self.scan(url, root: Self.repositoryRoot)
            inspected += result.inspected
            offenders += result.offenders
        }

        /// Guards the scanner itself. Brace matching that closes early finds no label block at all,
        /// which reads as a clean run rather than as the broken scan it is.
        #expect(inspected > 40, "Expected to find icon-only controls to check, found \(inspected)")
        #expect(
            offenders.isEmpty,
            "These controls show only an SF Symbol and need .help() or .accessibilityLabel(): \(offenders.sorted())"
        )
    }

    private static func scan(_ url: URL, root: URL) -> (inspected: Int, offenders: [String]) {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return (0, []) }
        let lines = source.components(separatedBy: .newlines)
        let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")

        var inspected = 0
        var offenders: [String] = []
        for (index, line) in lines.enumerated() where line.contains(labelMarker) {
            let (block, end) = labelBlock(lines, from: index)
            guard block.contains("Image(systemName:") else { continue }
            /// A symbol beside its own text is decoration, and the text is already the name.
            guard !block.contains("Text("), !block.contains("Label(") else { continue }

            inspected += 1
            let chain = lines[end ..< min(end + 18, lines.count)].joined(separator: "\n")
            guard !namingModifiers.contains(where: chain.contains) else { continue }
            offenders.append("\(relativePath):\(index + 1)")
        }
        return (inspected, offenders)
    }

    /// The label closure, brace matched. The opening line has to be measured from its `{` alone: the
    /// marker carries the previous closure's `}` too, and counting that balances the line to zero, so
    /// every block reads as one line long and no control is ever inspected.
    private static func labelBlock(_ lines: [String], from start: Int) -> (block: String, end: Int) {
        var depth = 0
        var collected: [String] = []
        for index in start ..< lines.count {
            let line = lines[index]
            var measured = line
            if index == start, let range = line.range(of: labelMarker) {
                measured = String(line[range.lowerBound...].dropFirst("} label: ".count))
            }
            collected.append(line)
            depth += measured.filter { $0 == "{" }.count
            depth -= measured.filter { $0 == "}" }.count
            if depth <= 0 { return (collected.joined(separator: "\n"), index) }
        }
        return (collected.joined(separator: "\n"), lines.count - 1)
    }
}
