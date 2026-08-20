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

    private static let appCatalogPaths = [
        "TablePro/Resources/Localizable.xcstrings",
        "TableProMobile/TableProMobile/Localizable.xcstrings"
    ]

    private static let shortcutCatalogPath = "TableProMobile/TableProMobile/AppShortcuts.xcstrings"

    private static let sharedSafeModeLabels = ["Confirm Writes", "Off", "Read-Only"]

    private static let koreanPlatformTerms = [
        "Deselect All": "전체 선택 해제",
        "Details": "세부사항",
        "Discard": "폐기",
        "Redo": "실행 복귀",
        "Select All": "전체 선택",
        "Undo": "실행 취소"
    ]

    private static let koreanNumericParticleTerms = [
        "Created as GitHub issue #%d": "GitHub 이슈 #%d(으)로 생성됨",
        "Process exited with code %d": "프로세스가 코드 %d(으)로 종료되었습니다"
    ]

    private static let koreanSupersededSpellings = [
        "모두 선택 해제": "전체 선택 해제",
        "변경사항": "변경 사항",
        "세부 정보": "세부사항"
    ]

    private static let koreanNounsEndingInPoliteSyllable: Set<String> = ["개요", "소요", "주요", "중요", "필요"]

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

        try Self.forEachTranslatableEntry(in: Self.catalogPaths) { path, key, entry in
            let value = entry.localizations?["ko"]?.stringUnit?.value ?? ""
            guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            missing.append("\(path): \(key)")
        }

        #expect(missing.isEmpty, "Missing Korean translations:\n\(missing.joined(separator: "\n"))")
    }

    @Test("Korean translations preserve format arguments and structured line breaks")
    func translationsPreserveStructure() throws {
        let expression = try Self.formatArgumentExpression()
        var mismatches: [String] = []

        try Self.forEachTranslatableEntry(in: Self.catalogPaths) { path, key, entry in
            guard let translation = entry.localizations?["ko"]?.stringUnit?.value else { return }
            let source = entry.localizations?["en"]?.stringUnit?.value ?? key
            let sourceSignature = Self.formatSignature(source, using: expression)
            let translationSignature = Self.formatSignature(translation, using: expression)
            let preservesLines = source.filter(\.isNewline).count == translation.filter(\.isNewline).count
            let preservesCodeFences = source.components(separatedBy: "```").count
                == translation.components(separatedBy: "```").count

            if sourceSignature != translationSignature || !preservesLines || !preservesCodeFences {
                mismatches.append("\(path): \(key)")
            }
        }

        #expect(mismatches.isEmpty, "Structurally unsafe Korean translations:\n\(mismatches.joined(separator: "\n"))")
    }

    @Test("Korean UI copy uses a consistent formal register")
    func koreanCopyUsesFormalRegister() throws {
        let expression = try Self.politeEndingExpression()
        var informal: [String] = []

        try Self.forEachKoreanTranslation(in: Self.catalogPaths) { path, key, translation in
            let endings = Self.informalPoliteEndings(in: translation, using: expression)
            guard !endings.isEmpty else { return }
            informal.append("\(path): \(key) ends a clause with \(endings.joined(separator: ", "))")
        }

        #expect(informal.isEmpty, "Informal Korean UI copy:\n\(informal.joined(separator: "\n"))")
    }

    @Test("Korean copy spells each term one way")
    func koreanCopyUsesOneSpellingPerTerm() throws {
        var drifted: [String] = []

        try Self.forEachKoreanTranslation(in: Self.catalogPaths) { path, key, translation in
            for (superseded, preferred) in Self.koreanSupersededSpellings where translation.contains(superseded) {
                drifted.append("\(path): \(key) uses \"\(superseded)\", expected \"\(preferred)\"")
            }
        }

        #expect(drifted.isEmpty, "Korean terms spelled two ways:\n\(drifted.joined(separator: "\n"))")
    }

    @Test("Korean platform terms match macOS conventions")
    func koreanPlatformTermsMatchConventions() throws {
        try Self.expectPinnedTranslations(Self.koreanPlatformTerms)
    }

    @Test("Korean numeric particles agree with the digit they follow")
    func koreanNumericParticlesAgreeWithDigits() throws {
        try Self.expectPinnedTranslations(Self.koreanNumericParticleTerms)
    }

    @Test("Shared Safe Mode labels exist in both app catalogs")
    func sharedSafeModeLabelsExistInBothApps() throws {
        for path in Self.appCatalogPaths {
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

        for path in Self.appCatalogPaths {
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
        let expression = try Self.formatArgumentExpression()
        let source = Self.formatSignature("Server error (%d): %@", using: expression)
        let dropped = Self.formatSignature("Server error: %@", using: expression)
        let duplicated = Self.formatSignature("Server error (%d): %@ %@", using: expression)
        let wrongType = Self.formatSignature("Server error (%@): %@", using: expression)
        let reordered = Self.formatSignature("Server error (%@): %d", using: expression)

        #expect(source != dropped)
        #expect(source != duplicated)
        #expect(source != wrongType)
        #expect(source != reordered)
    }

    @Test("Format signatures allow safe positional reordering and literals")
    func formatSignaturesAllowSafeForms() throws {
        let expression = try Self.formatArgumentExpression()
        let source = Self.formatSignature("%1$@ used %2$d rows and %3$lld bytes at %.3f%%", using: expression)
        let reordered = Self.formatSignature("%.3f%%: %3$lld bytes, %2$d rows, %1$@", using: expression)
        let prosePercent = Self.formatSignature("Use % to allow any host.", using: expression)

        #expect(source == reordered)
        #expect(prosePercent.isEmpty)
    }

    @Test("The register check reads clause endings, not a fixed list of phrases")
    func registerCheckDetectsEveryInformalEnding() throws {
        let expression = try Self.politeEndingExpression()
        let informal = [
            "터미널에서 다음을 실행하세요:",
            "브라우저에 코드를 입력하세요.",
            "이 탭을 닫을까요?",
            "변경 사항을 덮어쓸까요?",
            "연결에 실패했어요",
            "이미 저장되어 있죠",
            "지금 다시 시도해요 %@"
        ]
        let formal = [
            "터미널에서 다음을 실행하십시오:",
            "연결에 실패했습니다.",
            "이 탭을 닫으시겠습니까?",
            "관리자 권한이 필요합니다.",
            "인증 필요",
            "소요 시간",
            "개요 페이지를 여십시오.",
            "중요 정보 및 주요 설정"
        ]

        for copy in informal {
            #expect(!Self.informalPoliteEndings(in: copy, using: expression).isEmpty, "Missed: \(copy)")
        }
        for copy in formal {
            #expect(Self.informalPoliteEndings(in: copy, using: expression).isEmpty, "False positive: \(copy)")
        }
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
        let catalog = try Self.catalog(at: Self.shortcutCatalogPath)
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

    private static let catalogs: [String: Result<Catalog, SourceError>] = {
        let root = try? repoRoot()
        return (catalogPaths + [shortcutCatalogPath]).reduce(into: [:]) { catalogs, path in
            guard let root else {
                catalogs[path] = .failure(.repoRootNotFound)
                return
            }
            do {
                let data = try Data(contentsOf: root.appendingPathComponent(path))
                catalogs[path] = .success(try JSONDecoder().decode(Catalog.self, from: data))
            } catch {
                catalogs[path] = .failure(.unreadableCatalog(path, String(describing: error)))
            }
        }
    }()

    private static func catalog(at path: String) throws -> Catalog {
        guard let result = catalogs[path] else { throw SourceError.unknownCatalog(path) }
        return try result.get()
    }

    private static func forEachTranslatableEntry(
        in paths: [String],
        _ body: (String, String, Entry) throws -> Void
    ) throws {
        for path in paths {
            let catalog = try catalog(at: path)
            for (key, entry) in catalog.strings where !key.isEmpty && entry.shouldTranslate != false {
                try body(path, key, entry)
            }
        }
    }

    private static func forEachKoreanTranslation(
        in paths: [String],
        _ body: (String, String, String) throws -> Void
    ) throws {
        try forEachTranslatableEntry(in: paths) { path, key, entry in
            guard let translation = entry.localizations?["ko"]?.stringUnit?.value else { return }
            try body(path, key, translation)
        }
    }

    private static func expectPinnedTranslations(_ pinned: [String: String]) throws {
        var mismatches: [String] = []
        var present: Set<String> = []

        for path in appCatalogPaths {
            let strings = try catalog(at: path).strings
            for (key, expected) in pinned {
                guard let translation = strings[key]?.localizations?["ko"]?.stringUnit?.value else { continue }
                present.insert(key)
                guard translation != expected else { continue }
                mismatches.append("\(path): \(key) is \"\(translation)\", expected \"\(expected)\"")
            }
        }

        let unpinned = Set(pinned.keys).subtracting(present).sorted()
        #expect(unpinned.isEmpty, "Pinned Korean terms are in no app catalog:\n\(unpinned.joined(separator: "\n"))")
        #expect(mismatches.isEmpty, "Korean terms drifted:\n\(mismatches.joined(separator: "\n"))")
    }

    private static func politeEndingExpression() throws -> NSRegularExpression {
        try NSRegularExpression(pattern: #"[가-힣][요죠](?![가-힣])"#)
    }

    private static func informalPoliteEndings(
        in translation: String,
        using expression: NSRegularExpression
    ) -> [String] {
        let range = NSRange(translation.startIndex ..< translation.endIndex, in: translation)
        return expression.matches(in: translation, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: translation) else { return nil }
            let ending = String(translation[matchRange])
            return koreanNounsEndingInPoliteSyllable.contains(ending) ? nil : ending
        }
    }

    private static func propertyList(at path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent(path))
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let propertyList = value as? [String: Any] else { throw SourceError.invalidPropertyList }
        return propertyList
    }

    private static func formatArgumentExpression() throws -> NSRegularExpression {
        try NSRegularExpression(pattern: #"%(?:(\d+)\$)?((?:\.\d+)?(?:lld|ld|@|d|u|f|%))"#)
    }

    private static func formatSignature(_ value: String, using expression: NSRegularExpression) -> [String] {
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

    private struct Catalog: Decodable, Sendable {
        let strings: [String: Entry]
    }

    private struct Entry: Decodable, Sendable {
        let shouldTranslate: Bool?
        let localizations: [String: Localization]?
    }

    private struct Localization: Decodable, Sendable {
        let stringUnit: StringUnit?
        let stringSet: StringSet?
    }

    private struct StringUnit: Decodable, Sendable {
        let value: String?
    }

    private struct StringSet: Decodable, Sendable {
        let values: [String]
    }

    private enum SourceError: Error, Sendable {
        case invalidPropertyList
        case repoRootNotFound
        case unknownCatalog(String)
        case unreadableCatalog(String, String)
    }
}
