//
//  ClipboardInstallGuardTests.swift
//  TableProTests
//
//  `ClipboardService.shared` is process-wide, so a test that installs a fake and never puts the
//  real one back hands that fake to every test after it. A fake whose `writeText` does nothing
//  turned every later copy into an empty string, and the suites that read the copy back failed
//  on main for as long as the leak ran first.
//

import Foundation
import Testing

struct ClipboardInstallGuardTests {
    @Test("Every test that installs a clipboard puts the real one back")
    func everyInstallIsRestored() throws {
        let offenders = try Self.unrestoredInstalls()
        #expect(
            offenders.isEmpty,
            """
            Follow the install with `defer { ClipboardService.shared = NSPasteboardClipboardProvider() }`, \
            or keep the previous provider and restore it in a `defer`: \(offenders.sorted())
            """
        )
    }

    private static let install = "ClipboardService.shared = "
    private static let restore = "defer { ClipboardService.shared = "
    private static let reach = 3

    private static func unrestoredInstalls() throws -> [String] {
        let testRoot = try repoRoot().appendingPathComponent("TableProTests")
        guard let enumerator = FileManager.default.enumerator(
            at: testRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        var offenders: [String] = []
        for case let url as URL in enumerator
            where url.pathExtension == "swift" && url.lastPathComponent != "ClipboardInstallGuardTests.swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where line.contains(install) && !line.contains(restore) {
                let window = lines[max(0, index - reach) ... min(lines.count - 1, index + reach)]
                guard !window.contains(where: { $0.contains(restore) }) else { continue }
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        return offenders
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
