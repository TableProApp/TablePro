//
//  FixedFormatDateFormatterLocaleTests.swift
//  TableProTests
//

import Foundation
import Testing

/// A `DateFormatter` with a fixed `dateFormat` resolves `yyyy` against the *user's* calendar, so a
/// machine set to the Buddhist or Japanese calendar writes 2569 or R7 where the format meant 2026.
/// Apple's own guidance is to pin a POSIX locale for every fixed format. These values reach cell
/// text, the clipboard and export files, so this is wrong data rather than a display glitch.
@Suite("Fixed-format date formatters")
struct FixedFormatDateFormatterLocaleTests {
    @Test("A fixed format under a non-Gregorian calendar needs the POSIX locale to stay Gregorian")
    func posixLocaleKeepsTheGregorianYear() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-18T00:00:00Z"))
        let buddhist = Locale(identifier: "th_TH@calendar=buddhist")

        let unpinned = DateFormatter()
        unpinned.locale = buddhist
        unpinned.timeZone = TimeZone(identifier: "UTC")
        unpinned.dateFormat = "yyyy-MM-dd"

        let pinned = DateFormatter()
        pinned.locale = Locale(identifier: "en_US_POSIX")
        pinned.timeZone = TimeZone(identifier: "UTC")
        pinned.dateFormat = "yyyy-MM-dd"

        #expect(unpinned.string(from: date) != "2026-09-18")
        #expect(pinned.string(from: date) == "2026-09-18")
    }

    @Test("Every fixed-format date formatter in the codebase states its locale")
    func everyFixedFormatFormatterStatesItsLocale() throws {
        let root = try repositoryRoot()
        var offenders: [String] = []

        for directory in ["TablePro", "Plugins", "Packages", "TableProMobile"] {
            let base = root.appendingPathComponent(directory)
            guard FileManager.default.fileExists(atPath: base.path) else { continue }
            offenders.append(contentsOf: try offendingSites(under: base, root: root))
        }

        #expect(
            offenders.isEmpty,
            """
            These formatters assign a fixed `dateFormat` without stating a `locale`, so their year \
            follows the user's calendar: \(offenders.sorted())
            """
        )
    }

    private func offendingSites(under directory: URL, root: URL) throws -> [String] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        var offenders: [String] = []

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            guard !url.path.contains("/.build/"), !url.path.contains("/checkouts/") else { continue }

            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where line.contains(".dateFormat = \"") {
                guard !statesALocale(at: index, in: lines) else { continue }
                let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                offenders.append("\(relative):\(index + 1)")
            }
        }

        return offenders
    }

    /// A formatter built right there is judged from where it is built to eight lines past the
    /// format. One handed over by a factory (`makeFormatter { $0.dateFormat = ... }`) has its locale
    /// set out of sight, so the file as a whole has to state one.
    private func statesALocale(at index: Int, in lines: [String]) -> Bool {
        let searchStart = max(0, index - 20)
        let construction = lines[searchStart...index].lastIndex { $0.contains("DateFormatter(") }

        guard let construction else {
            return lines.contains { $0.contains(".locale = ") }
        }
        return lines[construction...min(lines.count - 1, index + 8)].contains { $0.contains(".locale = ") }
    }

    private func repositoryRoot(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.yml").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw LocaleScanError.repositoryRootNotFound
    }

    private enum LocaleScanError: Error {
        case repositoryRootNotFound
    }
}
