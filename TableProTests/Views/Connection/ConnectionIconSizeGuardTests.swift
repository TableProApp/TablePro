//
//  ConnectionIconSizeGuardTests.swift
//  TableProTests
//
//  The size of a database icon is owned by `ConnectionIconMetrics` and by nothing else. It was
//  typed at each call site before, and eight sites had drifted to five numbers: the same
//  connection was 18pt in the welcome list, 28pt in the import sheet beside it, 16pt in the form
//  that opened from it, and 26pt in the chooser that opened from that.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Connection icon size")
struct ConnectionIconSizeGuardTests {
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    private static let viewsRoot = repositoryRoot.appendingPathComponent("TablePro/Views")

    /// A line that starts drawing a database icon.
    private static let iconAnchors = ["iconImage", "ConnectionTypeIcon("]

    /// How far past the anchor a size modifier can still belong to that icon.
    private static let modifierWindow = 6

    private static func swiftFiles(in root: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    private func literalSize(in line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains(".frame(width:") || trimmed.contains("size:")
            || trimmed.contains(".font(.system(size:") else {
            return false
        }
        guard !trimmed.contains("ConnectionIconMetrics") else { return false }
        /// A digit anywhere in a size-bearing modifier is a number the call site chose for itself.
        return trimmed.contains { $0.isNumber }
    }

    @Test("Every database icon takes its size from ConnectionIconMetrics")
    func noCallSiteTypesItsOwnSize() throws {
        var offenders: [String] = []

        for file in try Self.swiftFiles(in: Self.viewsRoot) {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where Self.iconAnchors.contains(where: line.contains) {
                let upper = min(index + Self.modifierWindow, lines.count - 1)
                for offset in index ... upper where literalSize(in: lines[offset]) {
                    let name = file.lastPathComponent
                    offenders.append("\(name):\(offset + 1) \(lines[offset].trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            "These draw a database icon at a size of their own: \(offenders.joined(separator: ", "))"
        )
    }

    @Test("The row size stays small enough to read as a list")
    func rowSizeIsCompact() {
        #expect(ConnectionIconMetrics.row <= 16)
        #expect(ConnectionIconMetrics.row < ConnectionIconMetrics.chooser)
        #expect(ConnectionIconMetrics.chooser < ConnectionIconMetrics.hero)
    }

    @Test("A symbol is drawn smaller than its frame, because a point size names the em")
    func symbolPointsFitTheFrame() {
        for points in [ConnectionIconMetrics.row, ConnectionIconMetrics.chooser, ConnectionIconMetrics.hero] {
            #expect(ConnectionIconMetrics.symbolPoints(points) < points)
            #expect(ConnectionIconMetrics.symbolPoints(points) > points * 0.7)
        }
    }
}
