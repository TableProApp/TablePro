import Foundation
import Testing

@Suite("Korean localization sources")
struct KoreanLocalizationSourceTests {
    private static let catalogPaths = [
        "TablePro/InfoPlist.xcstrings",
        "TablePro/Resources/Localizable.xcstrings",
        "TableProMobile/TableProMobile/InfoPlist.xcstrings",
        "TableProMobile/TableProMobile/Localizable.xcstrings"
    ]

    private static let sharedSafeModeLabels = ["Confirm Writes", "Off", "Read-Only"]

    private static let koreanPlatformTerms = [
        "Details": "세부사항",
        "Discard": "폐기",
        "Redo": "실행 복귀",
        "Select All": "전체 선택"
    ]

    private static let sharedPackageSourcePaths = [
        "Packages/TableProCore/Sources/TableProImport/ConnectionExportCrypto.swift",
        "Packages/TableProCore/Sources/TableProImport/ConnectionExportEnvelope.swift",
        "Packages/TableProCore/Sources/TableProImport/ConnectionImportTypes.swift",
        "Packages/TableProCore/Sources/TableProModels/SafeModeLevel.swift",
        "Packages/TableProCore/Sources/TableProMSSQLCore/MSSQLCoreError.swift",
        "Packages/TableProCore/Sources/TableProSyncTransport/SyncError.swift",
        "Packages/TableProOracle/Sources/TableProOracleCore/OracleCoreError.swift",
        "Packages/TableProOracle/Sources/TableProOracleCore/OracleListenerRefusal.swift",
        "Plugins/MSSQLDriverPlugin/FreeTDSConnection.swift"
    ]

    private static let sharedPackageMultilineKeys = [
        "Could not complete Oracle native network encryption with this server. It may require an encryption or "
            + "checksum algorithm the driver does not support.",
        "Timed out completing Kerberos authentication. The Kerberos KDC (domain controller) may be unreachable, "
            + "the server's SPN may be missing, or this device's clock may be off. Check your network to the domain, "
            + "or use SQL Server Authentication."
    ]

    @Test("Every translatable catalog entry has a Korean value")
    func catalogsAreComplete() throws {
        var missing: [String] = []

        for path in Self.catalogPaths {
            let catalog = try Self.catalog(at: path)
            for (key, entry) in catalog.strings where !key.isEmpty && entry.shouldTranslate != false {
                guard let unit = entry.localizations?["ko"]?.stringUnit,
                      let value = unit.value,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    missing.append("\(path): \(key)")
                    continue
                }
            }
        }

        #expect(missing.isEmpty, "Missing Korean translations:\n\(missing.joined(separator: "\n"))")
    }

    @Test("Korean translations preserve format arguments and structured line breaks")
    func translationsPreserveStructure() throws {
        var mismatches: [String] = []

        for path in Self.catalogPaths {
            let catalog = try Self.catalog(at: path)
            for (key, entry) in catalog.strings where !key.isEmpty && entry.shouldTranslate != false {
                guard let translation = entry.localizations?["ko"]?.stringUnit?.value else { continue }
                let source = entry.localizations?["en"]?.stringUnit?.value ?? key
                let sourceSignature = try Self.formatSignature(source)
                let translationSignature = try Self.formatSignature(translation)
                let preservesLines = source.filter { $0.isNewline }.count == translation.filter { $0.isNewline }.count
                let preservesCodeFences = source.components(separatedBy: "```").count
                    == translation.components(separatedBy: "```").count

                if sourceSignature != translationSignature || !preservesLines || !preservesCodeFences {
                    mismatches.append("\(path): \(key)")
                }
            }
        }

        #expect(mismatches.isEmpty, "Structurally unsafe Korean translations:\n\(mismatches.joined(separator: "\n"))")
    }

    @Test("Korean UI copy uses a consistent formal register")
    func koreanCopyUsesFormalRegister() throws {
        var informal: [String] = []

        for path in Self.catalogPaths {
            let catalog = try Self.catalog(at: path)
            for (key, entry) in catalog.strings {
                guard let translation = entry.localizations?["ko"]?.stringUnit?.value else { continue }
                let usesInformalImperative = translation.range(
                    of: #"세요(?:[.!?]|$)"#,
                    options: .regularExpression
                ) != nil
                if usesInformalImperative || translation.contains("할까요?") {
                    informal.append("\(path): \(key)")
                }
            }
        }

        #expect(informal.isEmpty, "Informal Korean UI copy:\n\(informal.joined(separator: "\n"))")
    }

    @Test("Korean platform terms match macOS conventions")
    func koreanPlatformTermsMatchConventions() throws {
        let strings = try Self.catalog(at: "TablePro/Resources/Localizable.xcstrings").strings

        for (key, expected) in Self.koreanPlatformTerms {
            #expect(strings[key]?.localizations?["ko"]?.stringUnit?.value == expected)
        }

        #expect(
            strings["Created as GitHub issue #%d"]?.localizations?["ko"]?.stringUnit?.value
                == "GitHub 이슈 #%d(으)로 생성됨"
        )
        #expect(
            strings["Process exited with code %d"]?.localizations?["ko"]?.stringUnit?.value
                == "프로세스가 코드 %d(으)로 종료되었습니다"
        )
    }

    @Test("Shared Safe Mode labels exist in both app catalogs")
    func sharedSafeModeLabelsExistInBothApps() throws {
        let paths = [
            "TablePro/Resources/Localizable.xcstrings",
            "TableProMobile/TableProMobile/Localizable.xcstrings"
        ]

        for path in paths {
            let strings = try Self.catalog(at: path).strings
            for label in Self.sharedSafeModeLabels {
                #expect(strings[label]?.localizations?["ko"]?.stringUnit?.value?.isEmpty == false)
            }
        }
    }

    @Test("Shared package strings exist in both app catalogs")
    func sharedPackageStringsExistInBothApps() throws {
        var keys = try Set(Self.sharedPackageSourcePaths.flatMap { try Self.localizedKeys(in: $0) })
        keys.formUnion(Self.sharedPackageMultilineKeys)
        let paths = [
            "TablePro/Resources/Localizable.xcstrings",
            "TableProMobile/TableProMobile/Localizable.xcstrings"
        ]

        for path in paths {
            let strings = try Self.catalog(at: path).strings
            for key in keys {
                #expect(
                    strings[key]?.localizations?["ko"]?.stringUnit?.value?.isEmpty == false,
                    "Missing shared package translation in \(path): \(key)"
                )
            }
        }
    }

    @Test("Info catalogs cover every privacy usage description")
    func infoCatalogsCoverPrivacyUsageDescriptions() throws {
        let pairs = [
            ("TablePro/Info.plist", "TablePro/InfoPlist.xcstrings"),
            ("TableProMobile/TableProMobile/Info.plist", "TableProMobile/TableProMobile/InfoPlist.xcstrings")
        ]

        for (plistPath, catalogPath) in pairs {
            let plist = try Self.propertyList(at: plistPath)
            let descriptions = plist.compactMapValues { $0 as? String }
                .filter { $0.key.hasSuffix("UsageDescription") }
            let strings = try Self.catalog(at: catalogPath).strings

            #expect(Set(strings.keys) == Set(descriptions.keys))
            for (key, source) in descriptions {
                #expect(strings[key]?.localizations?["en"]?.stringUnit?.value == source)
                #expect(strings[key]?.localizations?["ko"]?.stringUnit?.value?.isEmpty == false)
            }
        }
    }

    @Test("Format signatures detect unsafe argument changes")
    func formatSignaturesDetectUnsafeChanges() throws {
        let source = try Self.formatSignature("Server error (%d): %@")
        let dropped = try Self.formatSignature("Server error: %@")
        let duplicated = try Self.formatSignature("Server error (%d): %@ %@")
        let wrongType = try Self.formatSignature("Server error (%@): %@")
        let reordered = try Self.formatSignature("Server error (%@): %d")

        #expect(source != dropped)
        #expect(source != duplicated)
        #expect(source != wrongType)
        #expect(source != reordered)
    }

    @Test("Format signatures allow safe positional reordering and literals")
    func formatSignaturesAllowSafeForms() throws {
        let source = try Self.formatSignature("%1$@ used %2$d rows and %3$lld bytes at %.3f%%")
        let reordered = try Self.formatSignature("%.3f%%: %3$lld bytes, %2$d rows, %1$@")
        let prosePercent = try Self.formatSignature("Use % to allow any host.")

        #expect(source == reordered)
        #expect(prosePercent.isEmpty)
    }

    @Test("Every README links to the other language versions")
    func readmeLinksAreComplete() throws {
        let expectedLinks = [
            "README.md": ["README.vi.md", "README.zh.md", "README.ko.md"],
            "README.vi.md": ["README.md", "README.zh.md", "README.ko.md"],
            "README.zh.md": ["README.md", "README.vi.md", "README.ko.md"],
            "README.ko.md": ["README.md", "README.vi.md", "README.zh.md"]
        ]
        let root = try Self.repoRoot()

        for (path, links) in expectedLinks {
            let contents = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            for link in links {
                #expect(contents.contains("href=\"\(link)\""), "\(path) does not link to \(link)")
            }
        }
    }

    @Test("Every App Shortcut phrase has a structurally safe Korean variant")
    func appShortcutPhrasesAreComplete() throws {
        let path = "TableProMobile/TableProMobile/AppShortcuts.xcstrings"
        let catalog = try Self.catalog(at: path)
        let expectedKeys = [
            "Add a row in ${applicationName}",
            "Add rows in ${applicationName}",
            "Open ${connection} in ${applicationName}"
        ]

        #expect(Set(catalog.strings.keys) == Set(expectedKeys))

        for (key, entry) in catalog.strings {
            let sourcePhrases = entry.localizations?["en"]?.stringSet?.values ?? []
            let phrases = entry.localizations?["ko"]?.stringSet?.values ?? []

            #expect(!phrases.isEmpty, "Missing Korean App Shortcut phrases for \(key)")
            #expect(phrases.count == sourcePhrases.count, "Mismatched App Shortcut phrase count for \(key)")
            for (source, phrase) in zip(sourcePhrases, phrases) {
                #expect(!phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(
                    Self.shortcutTokens(in: phrase).sorted() == Self.shortcutTokens(in: source).sorted(),
                    "Unsafe tokens in \(phrase)"
                )
            }
        }
    }

    private static func catalog(at path: String) throws -> Catalog {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent(path))
        return try JSONDecoder().decode(Catalog.self, from: data)
    }

    private static func propertyList(at path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent(path))
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let propertyList = value as? [String: Any] else { throw SourceError.invalidPropertyList }
        return propertyList
    }

    private static func formatSignature(_ value: String) throws -> [String] {
        let expression = try NSRegularExpression(
            pattern: #"%(?:(\d+)\$)?((?:\.\d+)?(?:lld|ld|@|d|u|f|%))"#
        )
        let range = NSRange(value.startIndex ..< value.endIndex, in: value)
        var implicitIndex = 1
        var signature: [String] = []

        for match in expression.matches(in: value, range: range) {
            guard let specifierRange = Range(match.range(at: 2), in: value) else { continue }
            let specifier = String(value[specifierRange])
            if specifier == "%" {
                signature.append("literal:%")
                continue
            }

            let index: Int
            if let explicitRange = Range(match.range(at: 1), in: value),
               let explicitIndex = Int(value[explicitRange]) {
                index = explicitIndex
            } else {
                index = implicitIndex
                implicitIndex += 1
            }
            signature.append("argument:\(index):\(specifier)")
        }

        return signature.sorted()
    }

    private static func shortcutTokens(in value: String) -> [String] {
        let expression = try? NSRegularExpression(pattern: #"\$\{[^}]+\}"#)
        let range = NSRange(value.startIndex ..< value.endIndex, in: value)
        let matches = expression?.matches(in: value, range: range) ?? []
        return matches.compactMap { match in
            Range(match.range, in: value).map { String(value[$0]) }
        }
    }

    private static func localizedKeys(in path: String) throws -> [String] {
        let source = try String(contentsOf: repoRoot().appendingPathComponent(path), encoding: .utf8)
        let expression = try NSRegularExpression(pattern: #"String\(localized:\s*\"((?:\\.|[^\"\\])*)\""#)
        let range = NSRange(source.startIndex ..< source.endIndex, in: source)

        return try expression.matches(in: source, range: range).compactMap { match in
            guard let keyRange = Range(match.range(at: 1), in: source) else { return nil }
            let encoded = Data("\"\(source[keyRange])\"".utf8)
            let key = try JSONDecoder().decode(String.self, from: encoded)
            return key.isEmpty ? nil : key
        }
    }

    private static func repoRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 12 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.yml").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw SourceError.repoRootNotFound
    }

    private struct Catalog: Decodable {
        let strings: [String: Entry]
    }

    private struct Entry: Decodable {
        let shouldTranslate: Bool?
        let localizations: [String: Localization]?
    }

    private struct Localization: Decodable {
        let stringUnit: StringUnit?
        let stringSet: StringSet?
    }

    private struct StringUnit: Decodable {
        let value: String?
    }

    private struct StringSet: Decodable {
        let values: [String]
    }

    private enum SourceError: Error {
        case invalidPropertyList
        case repoRootNotFound
    }
}
