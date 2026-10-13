//
//  PaneBackgroundGuardTests.swift
//  TableProTests
//
//  A List, Form or ScrollView draws its own background, and that background follows the system.
//  Hiding it, painting list rows, or wrapping a pane in the old `themedContent` surface is how panes
//  stopped matching an unthemed Mac app. A window's color comes only from ThemeWindowBackdrop.
//

import Foundation
import Testing

struct PaneBackgroundGuardTests {
    private static let windowBackdropOwner = "TablePro/Theme/ThemeWindowBackdrop.swift"

    // A clear backdrop is how a borderless panel takes its own shape; it fills nothing.
    private static let notClear = #"(?!\s*(?:NSColor)?\.clear\b)"#

    static func rules() throws -> [ThemeSourceScan.Rule] {
        [
            try ThemeSourceScan.Rule("hidden scroll content background", #"\.scrollContentBackground\(\s*\.hidden\s*\)"#),
            try ThemeSourceScan.Rule("themed content surface", #"\b[Tt]hemedContent"#),
            try ThemeSourceScan.Rule("list row background", #"\.listRowBackground\("#),
        ]
    }

    struct WindowRules {
        let write: ThemeSourceScan.Rule
        let named: ThemeSourceScan.Rule
        let own: ThemeSourceScan.Rule
        let subclass: ThemeSourceScan.Rule
        let local: ThemeSourceScan.Rule
    }

    static func windowRules() throws -> WindowRules {
        WindowRules(
            write: try ThemeSourceScan.Rule("background color write", #"\bbackgroundColor\s*=(?!=)"#),
            named: try ThemeSourceScan.Rule(
                "window background color",
                #"(?:\b\w*(?:[Ww]indow|[Pp]anel|[Ss]heet)\w*|\b(?:w|win|wnd))[?!]?\.backgroundColor\s*=(?!=)"# + notClear
            ),
            own: try ThemeSourceScan.Rule(
                "window subclass background color",
                #"(?:\bself\.|(?<![\w.?!)\]]))backgroundColor\s*=(?!=)"# + notClear
            ),
            subclass: try ThemeSourceScan.Rule("window subclass", #"\bclass\s+\w+\s*:\s*\w*(?:Window|Panel)\b"#),
            local: try ThemeSourceScan.Rule(
                "window local",
                #"\b(?:let|var)\s+(\w+)\s*=\s*[\w.?!]*\b\w*(?:[Ww]indow|[Pp]anel|[Ss]heet)\w*[?!]?"#
                    + #"(?:\s+as[?!]?\s+\w+)?\s*(?:$|[,{;]|else\b)|\b(\w+)\s*:\s*(?:\w+\.)?\w*(?:Window|Panel)\b"#
            )
        )
    }

    /// `let host = view.window` or `_ host: NSWindow` names a window without saying so.
    private static func windowLocals(in lines: [ThemeSourceScan.Line], rule: ThemeSourceScan.Rule) -> Set<String> {
        var names: Set<String> = []
        for line in lines {
            let text = line.text as NSString
            for match in rule.expression.matches(in: line.text, range: NSRange(location: 0, length: text.length)) {
                for group in 1 ..< match.numberOfRanges where match.range(at: group).location != NSNotFound {
                    names.insert(text.substring(with: match.range(at: group)))
                }
            }
        }
        return names
    }

    /// A bare `backgroundColor =` is the window's own only in a file that subclasses a window or panel.
    static func windowBackgroundWrites(in lines: [ThemeSourceScan.Line]) throws -> [String] {
        let rules = try windowRules()
        let candidates = lines.filter { $0.path != windowBackdropOwner }
        let windowFiles = Set(candidates.filter { rules.subclass.matches($0.text) }.map(\.path))
        var offenders = ThemeSourceScan.violations(in: candidates, rules: [rules.named])
            + ThemeSourceScan.violations(in: candidates.filter { windowFiles.contains($0.path) }, rules: [rules.own])

        for (_, file) in Dictionary(grouping: candidates, by: \.path) {
            let locals = windowLocals(in: file, rule: rules.local)
            guard !locals.isEmpty else { continue }
            let write = try ThemeSourceScan.Rule(
                "window local background color",
                #"(?<![\w.])(?:"# + locals.sorted().joined(separator: "|") + #")[?!]?\.backgroundColor\s*=(?!=)"# + notClear
            )
            offenders += ThemeSourceScan.violations(in: file.filter { !rules.named.matches($0.text) }, rules: [write])
        }
        return offenders
    }

    @Test("No pane hides its control's own background")
    func panesKeepTheirOwnBackground() throws {
        let rules = try Self.rules()
        let tree = try ThemeSourceScan.scan(["TablePro"], rules: rules)
        let offenders = ThemeSourceScan.violations(in: tree.lines, rules: rules)

        #expect(tree.fileCount > 1_000, "Scanned only \(tree.fileCount) files; the tree did not resolve")
        #expect(
            offenders.isEmpty,
            """
            Let the List, Form or ScrollView draw its own background and rows:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    @Test("Only the window backdrop sets a window's background color")
    func windowColorComesFromTheBackdrop() throws {
        let rules = try Self.windowRules()
        let tree = try ThemeSourceScan.scan(["TablePro"], rules: [rules.write])
        let offenders = try Self.windowBackgroundWrites(in: tree.lines)

        #expect(tree.fileCount > 1_000, "Scanned only \(tree.fileCount) files; the tree did not resolve")
        #expect(
            offenders.isEmpty,
            """
            Hold a ThemeWindowBackdrop instead; it sets the window color only while a theme sets \
            window.background and restores the system one otherwise:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    @Test("The guard flags a hidden background, painted rows and the themed surface")
    func matcherCatchesAViolation() throws {
        let sample = """
        Form { content }
            .scrollContentBackground(.hidden)
        List { rows }.themedContent()
        // .scrollContentBackground(.hidden) was removed
        ScrollView { rows }
            .scrollContentBackground(.visible)
        struct ThemedContentSurface: ViewModifier {}
        Text(name).listRowBackground(Color.clear)
        // .listRowBackground(fill) was removed
        """
        let lines = ThemeSourceScan.flaggedLines(in: sample, rules: try Self.rules())

        #expect(lines == [2, 3, 7, 8])
    }

    @Test("The guard flags a window color set outside the backdrop")
    func matcherCatchesAWindowColor() throws {
        let window = """
        final class SheetPanel: NSPanel {
            func configure() {
                backgroundColor = palette[.windowBackdrop]
                self.backgroundColor = .windowBackgroundColor
                backgroundColor = .clear
                layer?.backgroundColor = fill
                // backgroundColor = .red
                if backgroundColor == .clear {}
            }
        }
        """
        let controller = """
        final class PaneController: NSViewController {
            func configure() {
                backgroundColor = fill
                view.window?.backgroundColor = palette[.windowBackdrop]
                editorWindow.backgroundColor = .textBackgroundColor
                panel.backgroundColor = NSColor.clear
                scrollView.backgroundColor = fill
                textView.backgroundColor = fill
                sheet.backgroundColor = fill
                sheetController.window?.backgroundColor = fill
                win.backgroundColor = .clear
            }
        }
        """
        let locals = """
        func restyle(_ target: NSWindow, view: NSView) {
            target.backgroundColor = fill
            let w = view.window
            w?.backgroundColor = fill
            guard let host = view.window else { return }
            host.backgroundColor = fill
            let content = windowContent.scrollView
            content.backgroundColor = fill
            host.contentView?.backgroundColor = fill
        }
        """
        let subclass = """
        final class ToolWindow: EditorWindow {
            func configure() {
                backgroundColor = fill
            }
        }
        """
        let windowController = """
        final class ToolController: NSWindowController {
            func configure() {
                backgroundColor = fill
            }
        }
        """
        let lines = ThemeSourceScan.codeLines(of: window, path: "SheetPanel.swift")
            + ThemeSourceScan.codeLines(of: controller, path: "PaneController.swift")
            + ThemeSourceScan.codeLines(of: locals, path: "Restyle.swift")
            + ThemeSourceScan.codeLines(of: subclass, path: "ToolWindow.swift")
            + ThemeSourceScan.codeLines(of: windowController, path: "ToolController.swift")
            + ThemeSourceScan.codeLines(of: window, path: "TablePro/Theme/ThemeWindowBackdrop.swift")
        let flagged = try Self.windowBackgroundWrites(in: lines).map { $0.components(separatedBy: ": ")[0] }

        #expect(flagged.sorted() == [
            "PaneController.swift:10",
            "PaneController.swift:4",
            "PaneController.swift:5",
            "PaneController.swift:9",
            "Restyle.swift:2",
            "Restyle.swift:4",
            "Restyle.swift:6",
            "SheetPanel.swift:3",
            "SheetPanel.swift:4",
            "ToolWindow.swift:3",
        ])
    }
}
