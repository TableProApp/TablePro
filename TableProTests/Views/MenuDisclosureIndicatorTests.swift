//
//  MenuDisclosureIndicatorTests.swift
//  TableProTests
//
//  A SwiftUI `Menu` on macOS is an `NSPopUpButton` carrying its own `NSPopUpIndicatorView`, and a
//  `ControlGroup`'s menu segment carries the same one. A chevron passed as the label becomes the
//  control's icon and lands beside that indicator rather than replacing it, so the control shows
//  two. Five shipped that way: the Run split button, the connection form's Tags row, the query
//  editor's scope picker and both AI chat pickers.
//
//  The two dead ones are the reason a reviewer cannot catch this by reading. SwiftUI reduces a
//  macOS menu label to one image plus one text and silently drops the rest, so a chevron written
//  after an icon and a title renders nothing at all, and the source looks identical either way.
//
//  The second suite guards the name rather than the glyph, and it is the same kind of trap: the
//  modifier that looks like it supplies a name is the one that removes it.
//

import Foundation
import Testing

@Suite("Menu disclosure indicators")
struct MenuDisclosureIndicatorTests {
    private static let labelMarker = "} label: {"

    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    /// `.accessibilityLabel` on a `Menu` is not additive. Measured with System Events against a
    /// standalone SwiftUI app: a menu labelled `Text("Add tags")` publishes `AXTitle` "Add tags",
    /// and the same menu with `.accessibilityLabel(Text("Add tags"))` on it publishes an empty name.
    /// The modifier replaces what the label was providing, with nothing. Four controls in this app
    /// carried it and were silent to VoiceOver because of it, the result-set chooser among them,
    /// which is why two suites asserting on its name could never have passed.
    ///
    /// `.accessibilityElement(children: .contain)` ahead of the label is a different construction:
    /// the label then names the container that modifier creates rather than the menu, and that is
    /// the one form that names a pull-down whose label draws only an icon. The trailing pane's
    /// ellipsis menu relies on it, and `TrailingPaneSurfaceUITests` reads its name on CI.
    @Test("No menu names itself with accessibilityLabel")
    func menusCarryTheirNameInTheirLabel() throws {
        let viewsRoot = Self.repositoryRoot.appendingPathComponent("TablePro/Views")
        let enumerator = try #require(
            FileManager.default.enumerator(at: viewsRoot, includingPropertiesForKeys: nil)
        )

        var inspected = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relativePath = url.path.replacingOccurrences(of: Self.repositoryRoot.path + "/", with: "")
            let result = Self.scanForMisplacedNames(source, relativePath: relativePath)
            inspected += result.inspected
            offenders += result.offenders
        }

        #expect(inspected > 20, "Expected to find SwiftUI menus to check, found \(inspected)")
        #expect(
            offenders.isEmpty,
            "These menus name themselves with .accessibilityLabel, which leaves them nameless. Put the name in the label, as `Label { Text(name) } icon: { EmptyView() }` with .labelStyle(.iconOnly), or as the label's own Text: \(offenders.sorted())"
        )
    }

    @Test("A label on the menu itself is flagged, a label on a container wrapping it is not")
    func scannerTellsTheMenuFromItsContainer() {
        let namedMenu = """
            Menu {
                Button("Fields") {}
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .accessibilityLabel("Options")
            """
        let namedContainer = """
            Menu {
                Button("Fields") {}
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Options")
            """

        #expect(Self.scanForMisplacedNames(namedMenu, relativePath: "Menu.swift").offenders == ["Menu.swift:1"])
        #expect(Self.scanForMisplacedNames(namedContainer, relativePath: "Menu.swift").offenders.isEmpty)
    }

    private static func scanForMisplacedNames(
        _ source: String,
        relativePath: String
    ) -> (inspected: Int, offenders: [String]) {
        let lines = source.components(separatedBy: .newlines)

        var inspected = 0
        var offenders: [String] = []
        for (index, line) in lines.enumerated() where line.contains(labelMarker) {
            guard let opening = menuOpening(lines, closingLabelAt: index) else { continue }
            inspected += 1
            let end = labelBlockEnd(lines, from: index)
            let chain = lines[end ..< min(end + 14, lines.count)].joined(separator: "\n")
            guard let modifiers = chain.range(of: ".accessibilityLabel") else { continue }
            let precedingModifiers = chain[..<modifiers.lowerBound]
            /// Only the chain that belongs to this menu. A nested control's own modifiers sit
            /// deeper and are reached by their own iteration of this loop.
            guard !precedingModifiers.contains(labelMarker) else { continue }
            guard !precedingModifiers.contains(".accessibilityElement(children: .contain)") else { continue }
            offenders.append("\(relativePath):\(opening + 1)")
        }
        return (inspected, offenders)
    }

    @Test("No SwiftUI menu draws a chevron of its own")
    func menusLeaveTheDisclosureChevronToTheControl() throws {
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

        /// Guards the scanner itself. A brace match that closes early finds no menu at all, which
        /// reads as a clean run rather than as the broken scan it is.
        #expect(inspected > 20, "Expected to find SwiftUI menus to check, found \(inspected)")
        #expect(
            offenders.isEmpty,
            "These menus draw a chevron the control already draws. Let it draw its own, and keep the name with `Label { Text(name) } icon: { EmptyView() }` plus .labelStyle(.iconOnly): \(offenders.sorted())"
        )
    }

    /// Only menus. A plain `Button` presenting a `.popover` draws no indicator, so its hand-drawn
    /// chevron is the only affordance it has and is correct: `TypePickerFieldView` and
    /// `CopyObjectsConfigureView` both rely on that.
    private static func scan(_ url: URL, root: URL) -> (inspected: Int, offenders: [String]) {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return (0, []) }
        let lines = source.components(separatedBy: .newlines)
        let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")

        var inspected = 0
        var offenders: [String] = []

        for (index, line) in lines.enumerated() where isMenuInitializer(line) {
            inspected += 1
            guard line.contains("systemImage: \"chevron") else { continue }
            offenders.append("\(relativePath):\(index + 1)")
        }

        for (index, line) in lines.enumerated() where line.contains(labelMarker) {
            guard let opening = menuOpening(lines, closingLabelAt: index) else { continue }
            inspected += 1
            guard labelBlock(lines, from: index).contains("\"chevron") else { continue }
            offenders.append("\(relativePath):\(opening + 1)")
        }

        return (inspected, offenders)
    }

    /// `Menu("Title", systemImage: "…") { … }`, the form that carries its label on the initializer
    /// and so never opens a `label:` closure for the block scan below to find. The prefix check
    /// keeps `NSMenu(` and any other suffix match out.
    private static func isMenuInitializer(_ line: String) -> Bool {
        guard let range = line.range(of: "Menu(") else { return false }
        let preceding = line[line.startIndex ..< range.lowerBound].last
        return preceding.map { !$0.isLetter && !$0.isNumber && $0 != "." && $0 != "_" } ?? true
    }

    /// Walks back from a `} label: {` to the construction it closes and reports where that started,
    /// but only when it is a `Menu`. The content closure is arbitrary SwiftUI, so this counts braces
    /// rather than matching the previous line: a `Menu` holding a nested `Picker` or a `ForEach`
    /// sits many lines above its own label.
    private static func menuOpening(_ lines: [String], closingLabelAt index: Int) -> Int? {
        var depth = 1
        var cursor = index

        while cursor > 0 {
            cursor -= 1
            let line = lines[cursor]
            depth += line.filter { $0 == "}" }.count
            depth -= line.filter { $0 == "{" }.count
            guard depth <= 0 else { continue }
            return opensAMenu(line) ? cursor : nil
        }
        return nil
    }

    /// The trailing-closure form, wherever it sits on the line: `Menu {`, `return Menu {` and
    /// `let x = Menu {` are all the same construction. Anchoring this to the start of the trimmed
    /// line missed the query editor's scope picker and the AI chat mode picker, both of which
    /// return theirs.
    private static func opensAMenu(_ line: String) -> Bool {
        for marker in ["Menu {", "Menu{"] {
            guard let range = line.range(of: marker) else { continue }
            let preceding = line[line.startIndex ..< range.lowerBound].last
            let isWordBoundary = preceding.map { !$0.isLetter && !$0.isNumber && $0 != "." && $0 != "_" } ?? true
            if isWordBoundary { return true }
        }
        return false
    }

    /// The label closure, brace matched. The opening line has to be measured from its `{` alone:
    /// the marker carries the content closure's `}` too, and counting that balances the line to
    /// zero, so every block reads as one line long and no label is ever inspected.
    private static func labelBlock(_ lines: [String], from start: Int) -> String {
        let end = labelBlockEnd(lines, from: start)
        return lines[start ... end].joined(separator: "\n")
    }

    private static func labelBlockEnd(_ lines: [String], from start: Int) -> Int {
        var depth = 0
        for index in start ..< lines.count {
            let line = lines[index]
            var measured = line
            if index == start, let range = line.range(of: labelMarker) {
                measured = String(line[range.lowerBound...].dropFirst("} label: ".count))
            }
            depth += measured.filter { $0 == "{" }.count
            depth -= measured.filter { $0 == "}" }.count
            if depth <= 0 { return index }
        }
        return lines.count - 1
    }
}
