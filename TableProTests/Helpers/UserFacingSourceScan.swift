//
//  UserFacingSourceScan.swift
//  TableProTests
//

import Foundation

enum UserFacingSourceScan {
    static func scanAppTarget(
        offends: (_ line: String, _ previous: String) -> Bool
    ) throws -> (scanned: Int, offenders: [String]) {
        let root = try repoRoot().appendingPathComponent("TablePro", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw ScanError.sourceTreeNotFound
        }

        var scanned = 0
        var found: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            var previous = ""
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                defer { if !line.trimmingCharacters(in: .whitespaces).isEmpty { previous = line } }
                guard offends(line, previous) else { continue }
                found.append("\(url.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return (scanned, found.sorted())
    }

    static func userFacingCode(line: String, previous: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("//") else { return nil }
        guard !isLogMessage(trimmed, previous: previous.trimmingCharacters(in: .whitespaces)) else { return nil }
        return withoutTrailingComment(trimmed)
    }

    private static let levels = "(debug|info|notice|warning|error|fault|critical|trace|log)"
    private static let logCall = #"(\blogger|Logger|Log)\s*\.\s*"# + levels + #"\s*\(|Logger\([^)]*\)\s*\.\s*"#
        + levels + #"\s*\(|\bos_log\s*\("#
    private static let chainedLevel = #"^\.\s*"# + levels + #"\s*\("#
    private static let logReceiverAtEnd = #"(\blogger|Logger|Log|Logger\([^)]*\))\s*$"#

    /// The level name alone is not a log call: `.info(for:)` and a banner's `.notice(_:)` are user-facing.
    private static func isLogMessage(_ line: String, previous: String) -> Bool {
        if matches(line, logCall) { return true }
        let previousCode = previous.hasPrefix("//") ? "" : withoutTrailingComment(previous)
        if matches(line, chainedLevel), matches(previousCode, logReceiverAtEnd) { return true }
        return matches(previousCode, logCall) && leavesParenthesisOpen(previousCode)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func leavesParenthesisOpen(_ line: String) -> Bool {
        var depth = 0
        var insideQuotes = false
        var escaped = false
        for character in line {
            if escaped {
                escaped = false
                continue
            }
            switch character {
            case "\\": escaped = true
            case "\"": insideQuotes.toggle()
            case "(" where !insideQuotes: depth += 1
            case ")" where !insideQuotes: depth -= 1
            default: break
            }
        }
        return depth > 0
    }

    private static func withoutTrailingComment(_ line: String) -> String {
        let characters = Array(line)
        var insideQuotes = false
        var escaped = false
        for index in characters.indices {
            let character = characters[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "\"" {
                insideQuotes.toggle()
                continue
            }
            if !insideQuotes, character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                return String(characters[..<index])
            }
        }
        return line
    }

    private static func repoRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 12 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("TablePro.xcodeproj").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw ScanError.repoRootNotFound
    }

    private enum ScanError: Error {
        case repoRootNotFound
        case sourceTreeNotFound
    }
}
