//
//  ToolbarSourceAccessTests.swift
//  TableProTests
//

import Foundation
import Testing

/// Nothing in the app may act on what AppKit says is on screen in a toolbar.
///
/// Measured on macOS 27: one visit to Customize Toolbar leaves `NSToolbar.visibleItems` and
/// `NSToolbarItem.isVisible` over-reporting for the life of the item instance, listing items that
/// are hidden or clipped. The error always runs toward "on screen", and acting on it is what hands
/// `NSPopover` an anchor with no window, an `NSInvalidArgumentException` Swift cannot catch. The
/// toolbar keeps its own record instead, `ToolbarVisibility`, and nothing enforces reading that
/// record over AppKit's but this scan, the same shape `SyncMapperFieldAccessTests` uses to keep raw
/// `record["` out of the sync mappers.
///
/// Two scans, because the two properties are not equally ambiguous. `visibleItems` means one thing
/// anywhere, so the whole app is scanned for it. `isVisible` is also a window's, a panel's and a
/// dozen view models', so across the app it is flagged only on a receiver named for a toolbar item;
/// that heuristic misses `$0.isVisible`, `\.isVisible` and `items[i].isVisible`, which are exactly
/// how a toolbar's items get filtered. So the files that handle toolbar items are scanned for every
/// `isVisible` whatever its receiver, and the one read allowed there is named: the switcher's
/// `toolbar.isVisible`, which is whether the toolbar itself is shown and was measured to read
/// correctly after a palette visit.
struct ToolbarSourceAccessTests {
    private static let rootDirectory: URL = {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { directory.deleteLastPathComponent() }
        return directory
    }()

    private static let appDirectory: URL? = {
        let app = rootDirectory.appendingPathComponent("TablePro")
        return FileManager.default.fileExists(atPath: app.path) ? app : nil
    }()

    /// Every file that builds, reads or presents from a toolbar item. The directories are scanned
    /// whole, so a file added to one of them is covered the day it is added.
    private static let toolbarDirectories = [
        "TablePro/Core/Services/Infrastructure/Toolbar",
        "TablePro/Views/Toolbar",
    ]

    private static let toolbarFiles = [
        "TablePro/Views/Components/PopoverPresenter.swift",
        "TablePro/Views/Compare/CompareEndpointToolbarController.swift",
    ]

    /// Every `MainWindowToolbar` source, by prefix, beside the class itself.
    private static let toolbarFilePrefix = "TablePro/Core/Services/Infrastructure/MainWindowToolbar"

    /// The one read the toolbar scan allows, and where. Named by file and by the exact expression,
    /// so a second `toolbar.isVisible` anywhere else is still flagged.
    private static let allowedRead = (
        path: "TablePro/Views/Toolbar/ToolbarSwitcherPresenter.swift",
        expression: "toolbar.isVisible"
    )

    private static let isVisibleRead = try? NSRegularExpression(
        pattern: #"([A-Za-z_][A-Za-z0-9_]*)\s*[?!]?\s*\.isVisible\b"#
    )

    private static let anyVisibilityRead = try? NSRegularExpression(
        pattern: #"\.(isVisible|visibleItems)\b"#
    )

    private static func sources() throws -> [(path: String, text: String)] {
        guard let appDirectory,
              let enumerator = FileManager.default.enumerator(at: appDirectory, includingPropertiesForKeys: nil)
        else { return [] }
        return try enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { url in
                let path = url.path.replacingOccurrences(of: appDirectory.path, with: "TablePro")
                return (path, try String(contentsOf: url, encoding: .utf8))
            }
    }

    static func isToolbarSource(_ path: String) -> Bool {
        path.hasPrefix(toolbarFilePrefix)
            || toolbarFiles.contains(path)
            || toolbarDirectories.contains { path.hasPrefix($0 + "/") }
    }

    private static func toolbarSources() throws -> [(path: String, text: String)] {
        try sources().filter { isToolbarSource($0.path) }
    }

    /// The code on a line, with any comment dropped. The rule is written about in the comments that
    /// explain it, so a doc comment naming `visibleItems` is not a read of it.
    private static func code(of line: String) -> String {
        guard let comment = line.range(of: "//") else { return line }
        return String(line[..<comment.lowerBound])
    }

    /// The app-wide rule: any `visibleItems`, and `isVisible` on a receiver named for an item.
    static func readsToolbarVisibility(_ line: String) -> Bool {
        let code = code(of: line)
        if code.contains(".visibleItems") { return true }
        guard let isVisibleRead else { return false }
        let range = NSRange(code.startIndex..., in: code)
        return isVisibleRead.matches(in: code, range: range).contains { match in
            guard let receiverRange = Range(match.range(at: 1), in: code) else { return false }
            let receiver = code[receiverRange].lowercased()
            return receiver.hasSuffix("item") || receiver.hasSuffix("items")
        }
    }

    /// The toolbar-file rule: every `isVisible` and `visibleItems` in code, whatever the receiver,
    /// key paths included.
    static func readsAnyVisibility(_ line: String) -> Bool {
        let code = code(of: line)
        guard let anyVisibilityRead else { return false }
        return anyVisibilityRead.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
    }

    /// Whether a line's only visibility read is the allowed one. A line that also reads something
    /// else is not excused by carrying it.
    static func isAllowedRead(_ line: String, path: String) -> Bool {
        guard path == allowedRead.path else { return false }
        let remainder = code(of: line).replacingOccurrences(of: allowedRead.expression, with: "")
        return code(of: line).contains(allowedRead.expression) && !readsAnyVisibility(remainder)
    }

    private static func hits(
        in sources: [(path: String, text: String)],
        where reads: (String) -> Bool
    ) -> [(path: String, line: Int, code: String)] {
        sources.flatMap { source in
            source.text
                .components(separatedBy: .newlines)
                .enumerated()
                .filter { reads($0.element) }
                .map { (source.path, $0.offset + 1, $0.element.trimmingCharacters(in: .whitespaces)) }
        }
    }

    // MARK: - Reach

    @Test("The app scan reaches the app's sources")
    func sourcesAreReachable() throws {
        let sources = try Self.sources()
        #expect(sources.count > 100, "Found \(sources.count) sources; the guard below would pass vacuously")
    }

    /// A moved or renamed file would otherwise drop out of the toolbar scan and leave it green.
    @Test("The toolbar scan reaches every file it names, and the allowed read is among them")
    func toolbarScanReachesItsFiles() throws {
        let paths = Set(try Self.toolbarSources().map(\.path))

        #expect(paths.count >= 10, "Only \(paths.count) toolbar sources scanned: \(paths.sorted())")
        for file in Self.toolbarFiles + [Self.allowedRead.path] {
            #expect(paths.contains(file), "\(file) is not being scanned")
        }
        for directory in Self.toolbarDirectories {
            #expect(paths.contains { $0.hasPrefix(directory + "/") }, "Nothing scanned under \(directory)")
        }
        #expect(paths.contains(Self.toolbarFilePrefix + ".swift"))
        #expect(paths.filter { $0.hasPrefix(Self.toolbarFilePrefix) }.count >= 5)
    }

    // MARK: - Matchers

    @Test("The app-wide matcher tells a toolbar item's visibility from the toolbar's own")
    func matcherKeysOnTheReceiver() {
        #expect(Self.readsToolbarVisibility("let shown = toolbar.visibleItems ?? []"))
        #expect(Self.readsToolbarVisibility("guard item.isVisible else { return }"))
        #expect(Self.readsToolbarVisibility("if toolbarItem?.isVisible == true {"))
        #expect(Self.readsToolbarVisibility("let on = subitem.isVisible && group.isHidden"))

        #expect(!Self.readsToolbarVisibility("guard let toolbar = window?.toolbar, toolbar.isVisible else {"))
        #expect(!Self.readsToolbarVisibility("toolbarVisible: window.toolbar?.isVisible ?? false"))
        #expect(!Self.readsToolbarVisibility("mentionState.isVisible = true"))
        #expect(!Self.readsToolbarVisibility("/// `NSToolbar.visibleItems` over-reports after a palette visit."))
    }

    /// The forms the receiver heuristic cannot see, which is why the toolbar files take this one.
    @Test("The toolbar matcher flags every read, whatever its receiver")
    func toolbarMatcherFlagsEveryRead() {
        #expect(Self.readsAnyVisibility("let shown = toolbar.items.filter { $0.isVisible }"))
        #expect(Self.readsAnyVisibility("let shown = toolbar.items.filter(\\.isVisible)"))
        #expect(Self.readsAnyVisibility("if toolbar.items[i].isVisible {"))
        #expect(Self.readsAnyVisibility("let on = toolbar.items.first { $0.itemIdentifier == id }?.isVisible"))
        #expect(Self.readsAnyVisibility("guard anchor.isVisible else { return nil }"))
        #expect(Self.readsAnyVisibility("let shown = toolbar.visibleItems ?? []"))

        #expect(!Self.readsAnyVisibility("/// Reading `item.isVisible` after a palette visit over-reports."))
        #expect(!Self.readsAnyVisibility("let hidden = visibility.hides(id) // not `.isVisible`"))
        #expect(!Self.readsAnyVisibility("item.isHidden = visibility.hides(item.itemIdentifier)"))
        #expect(!Self.readsAnyVisibility("let isVisibleNow = true"))
    }

    @Test("Only the switcher's own toolbar read is allowed, and only on its own")
    func allowanceIsExact() {
        let path = Self.allowedRead.path
        #expect(Self.isAllowedRead("guard let toolbar = window?.toolbar, toolbar.isVisible else { return nil }", path: path))
        #expect(!Self.isAllowedRead("guard toolbar.isVisible, item.isVisible else { return nil }", path: path))
        #expect(!Self.isAllowedRead("guard toolbar.isVisible else { return nil }", path: "TablePro/Views/Toolbar/Other.swift"))
        #expect(!Self.isAllowedRead("guard anchor.isVisible else { return nil }", path: path))
    }

    // MARK: - Scans

    @Test("Nothing in the app reads NSToolbar.visibleItems or an item's isVisible")
    func noVisibilityReads() throws {
        let offenders = Self.hits(in: try Self.sources(), where: Self.readsToolbarVisibility)
            .filter { !Self.isAllowedRead($0.code, path: $0.path) }
            .map { "\($0.path):\($0.line): \($0.code)" }

        #expect(offenders.isEmpty, """
        These read AppKit's report of which toolbar items are on screen, which one Customize Toolbar \
        visit leaves over-reporting for good. Ask the toolbar's own record, \
        `MainWindowToolbar.visibility`, whether an item is hidden, and `NSToolbar.items` which \
        instance it is.
        \(offenders.joined(separator: "\n"))
        """)
    }

    @Test("The toolbar files read no visibility at all, beyond whether the toolbar is shown")
    func toolbarFilesReadNoVisibility() throws {
        let hits = Self.hits(in: try Self.toolbarSources(), where: Self.readsAnyVisibility)
        let allowed = hits.filter { Self.isAllowedRead($0.code, path: $0.path) }
        let offenders = hits
            .filter { !Self.isAllowedRead($0.code, path: $0.path) }
            .map { "\($0.path):\($0.line): \($0.code)" }

        #expect(allowed.count == 1, """
        The switcher's `toolbar.isVisible` read is the one allowance, and it should be there exactly \
        once. Found \(allowed.count): \(allowed.map { "\($0.path):\($0.line)" })
        """)
        #expect(offenders.isEmpty, """
        A toolbar file reads `isVisible` or `visibleItems`, which one Customize Toolbar visit leaves \
        over-reporting. Ask `MainWindowToolbar.visibility` whether an item is hidden.
        \(offenders.joined(separator: "\n"))
        """)
    }
}
