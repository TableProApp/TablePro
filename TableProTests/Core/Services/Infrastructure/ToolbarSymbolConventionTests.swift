//
//  ToolbarSymbolConventionTests.swift
//  TableProTests
//
//  A window toolbar draws outline glyphs. A fill is the HIG's variant for selection, so a filled
//  glyph on a command reads as state that is not there, and from macOS 26 a circled one draws a
//  border inside the border its item already has. Four shipped that way: Save was the filled,
//  circled check the rest of the app uses for "succeeded", Actions and the data file's Filters
//  were circled, and the License pane was the one filled glyph of twelve in Settings.
//
//  A glyph whose form depends on the release comes from `ToolbarSymbols`, which is why a literal
//  with a `circle` or `fill` component has no business in these files at all. The SwiftUI toolbars
//  (welcome, Integrations) take theirs from the same owner but are not scanned: their files also
//  draw content, where a circled or filled status glyph is the right one.
//

import Foundation
import Testing

struct ToolbarSymbolConventionTests {
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    /// The Settings panes are toolbar items too, built from the tab view rather than by hand, so
    /// the file never names `NSToolbarItem` and has to be listed.
    private static let additionalFiles = ["TablePro/Views/Settings/SettingsView.swift"]

    private static let bannedComponents: Set<Substring> = ["circle", "fill"]

    /// Comments are dropped before the scan, because a comment may name what was removed.
    private static func code(of source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Every string literal shaped like a symbol name: lowercase words and digits joined by dots.
    private static func symbolLiterals(in source: String) -> [String] {
        guard let pattern = try? NSRegularExpression(pattern: "\"([a-z0-9]+(?:\\.[a-z0-9]+)+)\"") else { return [] }
        let text = code(of: source) as NSString
        return pattern
            .matches(in: text as String, range: NSRange(location: 0, length: text.length))
            .map { text.substring(with: $0.range(at: 1)) }
    }

    /// By component, not by substring: `arrow.triangle.2.circlepath` and `rectangle.inset.filled`
    /// are outline glyphs whose names happen to contain the letters.
    private static func isEnclosedOrFilled(_ name: String) -> Bool {
        name.split(separator: ".").contains { bannedComponents.contains($0) }
    }

    private static func buildsToolbarItems(_ source: String) -> Bool {
        source.contains("NSToolbarItem") || source.contains("NSMenuToolbarItem")
    }

    @Test("No file that builds toolbar items names a circled or filled symbol")
    func toolbarFilesNameNoEnclosedOrFilledSymbol() throws {
        let appRoot = Self.repositoryRoot.appendingPathComponent("TablePro")
        let enumerator = try #require(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))

        var sources: [(path: String, source: String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            guard Self.buildsToolbarItems(source) else { continue }
            sources.append((url.path.replacingOccurrences(of: Self.repositoryRoot.path + "/", with: ""), source))
        }
        for path in Self.additionalFiles {
            let url = Self.repositoryRoot.appendingPathComponent(path)
            sources.append((path, try String(contentsOf: url, encoding: .utf8)))
        }

        var inspected = 0
        var offenders: [String] = []
        for (path, source) in sources {
            let literals = Self.symbolLiterals(in: source)
            inspected += literals.count
            offenders += literals.filter(Self.isEnclosedOrFilled).map { "\(path): \($0)" }
        }

        /// Guards the scan itself: a root that stopped resolving reads as a clean run.
        #expect(sources.count > 8, "Expected to find the toolbar sources, found \(sources.count)")
        #expect(inspected > 15, "Expected to find symbol names to check, found \(inspected)")
        #expect(
            offenders.isEmpty,
            "A toolbar glyph is outline. Take one whose form follows the release from ToolbarSymbols: \(offenders.sorted())"
        )
    }

    /// A scan that stops matching anything passes forever. This pins both halves.
    @Test("The scan catches a circled or filled name and leaves an outline one alone")
    func scanTellsAVariantFromALookalike() {
        let flagged = [
            "            symbol: \"checkmark.circle.fill\",",
            "        item.image = NSImage(systemSymbolName: \"ellipsis.circle\", accessibilityDescription: label)",
            "        case .account: \"key.fill\"",
            "                symbolProvider: { \"line.3.horizontal.decrease.circle\" }",
        ]
        for line in flagged {
            #expect(Self.symbolLiterals(in: line).contains(where: Self.isEnclosedOrFilled), "\(line)")
        }

        let allowed = [
            "            symbol: \"clock.arrow.circlepath\",",
            "            symbol: \"arrow.triangle.2.circlepath\",",
            "                        ? \"rectangle.inset.filled\"",
            "            symbol: \"square.and.arrow.down.on.square\",",
            "    /// It used to draw \"checkmark.circle.fill\".",
        ]
        for line in allowed {
            #expect(Self.symbolLiterals(in: line).contains(where: Self.isEnclosedOrFilled) == false, "\(line)")
        }
    }
}
