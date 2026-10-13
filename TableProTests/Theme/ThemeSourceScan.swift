//
//  ThemeSourceScan.swift
//  TableProTests
//

import Foundation
@testable import TablePro

/// Reads the real source tree for the theme guard suites. Comments are dropped before matching,
/// because a comment may name exactly what was removed.
enum ThemeSourceScan {
    struct Line {
        let path: String
        let number: Int
        let text: String

        var location: String { "\(path):\(number)" }
    }

    struct Tree {
        let fileCount: Int
        let lines: [Line]
    }

    struct Rule {
        let name: String
        let expression: NSRegularExpression

        init(_ name: String, _ pattern: String) throws {
            self.name = name
            expression = try NSRegularExpression(pattern: pattern)
        }

        func matches(_ text: String) -> Bool {
            expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    enum ScanError: Error {
        case repositoryRootNotFound
        case treeNotFound(String)
    }

    static func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let manifest = directory.appendingPathComponent("project.yml").path
            let themeTree = directory.appendingPathComponent("TablePro/Theme").path
            if FileManager.default.fileExists(atPath: manifest), FileManager.default.fileExists(atPath: themeTree) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        throw ScanError.repositoryRootNotFound
    }

    /// Hidden directories (`.build`, `.swiftpm`) are never source, and `skipping` names more by
    /// their last path component, such as a package's `Tests`. A file whose raw text matches none
    /// of `rules` is counted but not lexed, which keeps an unoptimized test build fast.
    static func scan(
        _ trees: [String],
        skipping: Set<String> = [],
        rules: [Rule] = [],
        including include: (String) -> Bool = { _ in true }
    ) throws -> Tree {
        let root = try repositoryRoot()
        var fileCount = 0
        var lines: [Line] = []

        for tree in trees {
            let base = root.appendingPathComponent(tree, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: base,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                throw ScanError.treeNotFound(tree)
            }

            for case let url as URL in enumerator {
                if skipping.contains(url.lastPathComponent),
                   (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.pathExtension == "swift" else { continue }

                let path = relativePath(of: url, in: base, tree: tree)
                guard include(path) else { continue }

                fileCount += 1
                let source = try String(contentsOf: url, encoding: .utf8)
                guard rules.isEmpty || rules.contains(where: { $0.matches(source) }) else { continue }
                lines += codeLines(of: source, path: path)
            }
        }

        return Tree(fileCount: fileCount, lines: lines)
    }

    static func violations(in lines: [Line], rules: [Rule]) -> [String] {
        lines.flatMap { line in
            rules
                .filter { $0.matches(line.text) }
                .map { "\(line.location): \($0.name): \(line.text.trimmingCharacters(in: .whitespaces))" }
        }
    }

    /// The line numbers of an inline sample that the rules flag, for a guard's self-test.
    static func flaggedLines(in sample: String, rules: [Rule]) -> Set<Int> {
        let lines = codeLines(of: sample, path: "Sample.swift").filter { line in
            rules.contains { $0.matches(line.text) }
        }
        return Set(lines.map(\.number))
    }

    /// `.editorText` or `ThemeSlot.editorText`. A dot after an identifier, `)` or `]` is some
    /// other property (`self.editorText`), and the closing word boundary keeps `.gridSelection`
    /// from matching inside `.gridSelectionText`.
    static func slotTokenPattern(_ slots: [ThemeSlot] = ThemeSlot.allCases) -> String {
        let names = slots.map { String(describing: $0) }.joined(separator: "|")
        return #"(?:(?<![\w)\]?!])|(?<=ThemeSlot))\.("# + names + #")\b"#
    }

    static func codeLines(of source: String, path: String) -> [Line] {
        var state = LexState()
        var lines: [Line] = []
        for (index, raw) in source.components(separatedBy: "\n").enumerated() {
            let code = strip(raw, state: &state)
            guard !code.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            lines.append(Line(path: path, number: index + 1, text: code))
        }
        return lines
    }

    private struct LexState {
        var inBlockComment = false
        var inMultilineString = false
    }

    private static let slash = UInt8(ascii: "/")
    private static let star = UInt8(ascii: "*")
    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")

    /// Enough of a lexer to drop `//` and `/* */` comments without cutting a `//` inside a string
    /// literal, such as a URL. It works on UTF-8 bytes: every token it looks for is ASCII, and no
    /// byte of a multi-byte character is.
    private static func strip(_ line: String, state: inout LexState) -> String {
        let bytes = Array(line.utf8)
        var kept: [UInt8] = []
        kept.reserveCapacity(bytes.count)
        var index = 0
        var inString = false

        func pair(_ first: UInt8, _ second: UInt8, at position: Int) -> Bool {
            position + 1 < bytes.count && bytes[position] == first && bytes[position + 1] == second
        }

        func tripleQuote(at position: Int) -> Bool {
            position + 2 < bytes.count
                && bytes[position] == quote && bytes[position + 1] == quote && bytes[position + 2] == quote
        }

        while index < bytes.count {
            let byte = bytes[index]

            if state.inBlockComment {
                if pair(star, slash, at: index) {
                    state.inBlockComment = false
                    index += 2
                } else {
                    index += 1
                }
                continue
            }

            if state.inMultilineString {
                if tripleQuote(at: index) {
                    state.inMultilineString = false
                    kept += [quote, quote, quote]
                    index += 3
                } else {
                    kept.append(byte)
                    index += 1
                }
                continue
            }

            if inString {
                kept.append(byte)
                if byte == backslash, index + 1 < bytes.count {
                    kept.append(bytes[index + 1])
                    index += 2
                    continue
                }
                if byte == quote {
                    inString = false
                }
                index += 1
                continue
            }

            if pair(slash, slash, at: index) {
                break
            }
            if pair(slash, star, at: index) {
                state.inBlockComment = true
                index += 2
                continue
            }
            if tripleQuote(at: index) {
                state.inMultilineString = true
                kept += [quote, quote, quote]
                index += 3
                continue
            }
            if byte == quote {
                inString = true
            }
            kept.append(byte)
            index += 1
        }

        return String(bytes: kept, encoding: .utf8) ?? line
    }

    private static func relativePath(of url: URL, in base: URL, tree: String) -> String {
        let basePath = base.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(basePath + "/") else { return url.lastPathComponent }
        return tree + filePath.dropFirst(basePath.count)
    }
}
