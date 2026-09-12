//
//  PreferenceKeysGuardTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Preference key registry & guard")
struct PreferenceKeysGuardTests {
    @Test("Registered keys are unique and namespaced")
    func registryIsCleanlyNamespaced() {
        let names = PreferenceKeys.registeredKeyNames
        #expect(Set(names).count == names.count)
        for name in names {
            #expect(name.hasPrefix("com.TablePro."), "Key '\(name)' is outside the com.TablePro namespace")
        }
    }

    @Test("No off-namespace forKey: literals outside the frozen baseline")
    func noNewRawForKeyLiterals() throws {
        let offenders = try Self.scan(pattern: #"forKey:\s*"([^"\\]+)""#, ignoringCalls: Self.nonPreferenceCalls)
            .filter { !$0.hasPrefix("com.TablePro") && Self.grandfatheredForKey[$0] == nil }
        #expect(offenders.isEmpty, "Route new UserDefaults keys through PreferenceKeys: \(offenders.sorted())")
    }

    @Test("No off-namespace @AppStorage literals outside the frozen baseline")
    func noNewRawAppStorageLiterals() throws {
        let offenders = try Self.scan(pattern: #"@AppStorage\(\s*"([^"\\]+)""#)
            .filter { !$0.hasPrefix("com.TablePro") && Self.grandfatheredAppStorage[$0] == nil }
        #expect(offenders.isEmpty, "Route new @AppStorage keys through the preferences layer: \(offenders.sorted())")
    }

    /// `forKey:` is not UserDefaults' label alone: `Dictionary.removeValue(forKey:)` and
    /// `CALayer.add(_:forKey:)` spell it the same way, and a text scan cannot tell them apart. The
    /// baseline grew one entry per dictionary key instead, three of its five, and the fourth arrived
    /// as `removeValue(forKey: "LC_ALL")` in the dump environment (#2747), which failed this suite on
    /// main for a value no preference has ever read. Naming the calls that are not preferences keeps
    /// the baseline for the keys that genuinely are.
    private static let nonPreferenceCalls: Set<String> = [
        "removeValue", "updateValue", "add", "animation", "removeAnimation",
    ]

    private static let grandfatheredForKey: [String: String] = [
        "AppleLanguages": "Apple system default written when switching app language",
        "NSTableViewDefaultSizeMode": "Apple system default read by the workspace rail for Sidebar icon size, never written",
    ]

    private static let grandfatheredAppStorage: [String: String] = [
        "hideExportSuccessDialog": "legacy export flag, migrates to PreferenceKeys in a later phase",
        "skipSchemaPreview": "legacy schema-preview flag, migrates to PreferenceKeys in a later phase",
        "structureCodeFontSize": "legacy structure font size, migrates to PreferenceKeys in a later phase",
    ]

    private static func scan(pattern: String, ignoringCalls ignored: Set<String> = []) throws -> Set<String> {
        let sourceRoot = try repoRoot().appendingPathComponent("TablePro")
        let regex = try NSRegularExpression(pattern: pattern)
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        var matches: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) where match.numberOfRanges > 1 {
                guard let captured = Range(match.range(at: 1), in: text),
                      let start = Range(match.range, in: text)?.lowerBound
                else { continue }
                if let call = enclosingCall(in: text, at: start), ignored.contains(call) { continue }
                matches.insert(String(text[captured]))
            }
        }
        return matches
    }

    /// The function whose argument list the match sits in, found by walking back to the innermost
    /// unmatched `(`. Nested parentheses in an earlier argument are skipped, so
    /// `layer.add(makeBlinkAnimation(), forKey: "blink")` reports `add` rather than
    /// `makeBlinkAnimation`.
    private static func enclosingCall(in text: String, at index: String.Index) -> String? {
        var depth = 0
        var cursor = index
        while cursor > text.startIndex {
            cursor = text.index(before: cursor)
            let character = text[cursor]
            if character == ")" {
                depth += 1
            } else if character == "(" {
                if depth == 0 { return identifier(in: text, endingBefore: cursor) }
                depth -= 1
            } else if character == "\n", depth == 0 {
                continue
            }
        }
        return nil
    }

    private static func identifier(in text: String, endingBefore index: String.Index) -> String? {
        var end = index
        while end > text.startIndex {
            let previous = text.index(before: end)
            let character = text[previous]
            guard character.isLetter || character.isNumber || character == "_" else { break }
            end = previous
        }
        guard end < index else { return nil }
        return String(text[end ..< index])
    }

    private static func repoRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 12 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("TablePro.xcodeproj").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw GuardError.repoRootNotFound
    }

    private enum GuardError: Error {
        case repoRootNotFound
    }
}
