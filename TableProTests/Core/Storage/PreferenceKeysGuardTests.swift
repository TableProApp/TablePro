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
        let offenders = try Self.scan(pattern: #"forKey:\s*"([^"\\]+)""#)
            .filter { !$0.hasPrefix("com.TablePro") && Self.grandfatheredForKey[$0] == nil }
        #expect(offenders.isEmpty, "Route new UserDefaults keys through PreferenceKeys: \(offenders.sorted())")
    }

    @Test("No off-namespace @AppStorage literals outside the frozen baseline")
    func noNewRawAppStorageLiterals() throws {
        let offenders = try Self.scan(pattern: #"@AppStorage\(\s*"([^"\\]+)""#)
            .filter { !$0.hasPrefix("com.TablePro") && Self.grandfatheredAppStorage[$0] == nil }
        #expect(offenders.isEmpty, "Route new @AppStorage keys through the preferences layer: \(offenders.sorted())")
    }

    private static let grandfatheredForKey: [String: String] = [
        "AppleLanguages": "Apple system default written when switching app language",
        "blink": "CALayer animation key in VimCursorManager, not a preference",
        "preConnectScript": "additionalFields dictionary key in ConnectionFormCoordinator, not a preference",
    ]

    private static let grandfatheredAppStorage: [String: String] = [
        "hideExportSuccessDialog": "legacy export flag, migrates to PreferenceKeys in a later phase",
        "skipSchemaPreview": "legacy schema-preview flag, migrates to PreferenceKeys in a later phase",
        "structureCodeFontSize": "legacy structure font size, migrates to PreferenceKeys in a later phase",
    ]

    private static func scan(pattern: String) throws -> Set<String> {
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
                if let captured = Range(match.range(at: 1), in: text) {
                    matches.insert(String(text[captured]))
                }
            }
        }
        return matches
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
