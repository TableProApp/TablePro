//
//  SQLFormatterRulesTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProAutocomplete
import TableProSyncTransport
import Testing

@MainActor
struct SQLFormatterRulesTests {
    private static let custom = SQLFormatterOptions(
        indentStyle: .tabs,
        indentWidth: 4,
        keywordCase: .lower,
        functionCase: .upper,
        commaPosition: .leading,
        lineWidth: 100,
        joinCondition: .sameLine,
        alignAliases: true
    )

    private func decode(_ json: String) throws -> SQLFormatterOptions {
        try SQLFormatterRulesFile.decode(Data(json.utf8))
    }

    // MARK: - Rules file

    @Test("A rules file round-trips every rule")
    func fileRoundTrip() throws {
        let data = try SQLFormatterRulesFile.encode(Self.custom)
        #expect(try SQLFormatterRulesFile.decode(data) == Self.custom)
    }

    @Test("A rules file names every rule, so another Mac reads no default of its own")
    func fileWritesEveryKey() throws {
        let data = try SQLFormatterRulesFile.encode(.default)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let everyKey = Set(SQLFormatterOptions.CodingKeys.allCases.map { $0.stringValue })
        #expect(Set(object.keys) == everyKey)
        #expect(object["indentStyle"] as? String == "spaces")
        #expect(object["commaPosition"] as? String == "trailing")
        #expect(object["joinCondition"] as? String == "newLine")
    }

    @Test("A key the file leaves out takes the default")
    func missingKeysTakeDefaults() throws {
        #expect(try decode("{}") == .default)
        var expected = SQLFormatterOptions.default
        expected.commaPosition = .leading
        #expect(try decode(#"{"commaPosition": "leading"}"#) == expected)
    }

    @Test("A key this build does not know is ignored")
    func unknownKeysAreIgnored() throws {
        let options = try decode(#"{"language": "postgresql", "indentWidth": 4}"#)
        #expect(options.indentWidth == 4)
    }

    @Test(
        "A value this build cannot read names its key",
        arguments: [
            (#"{"keywordCase": "title"}"#, "keywordCase"),
            (#"{"indentWidth": 0}"#, "indentWidth"),
            (#"{"indentWidth": 17}"#, "indentWidth"),
            (#"{"indentWidth": "four"}"#, "indentWidth"),
            (#"{"lineWidth": -1}"#, "lineWidth"),
            (#"{"alignAliases": "yes"}"#, "alignAliases"),
        ]
    )
    func invalidValueNamesKey(json: String, key: String) {
        #expect(throws: SQLFormatterRulesError.invalidValue(key: key)) {
            try self.decode(json)
        }
    }

    @Test("A file that is not a JSON object is refused", arguments: ["", "[]", "not json", "{"])
    func notJSONIsRefused(json: String) {
        #expect(throws: SQLFormatterRulesError.notJSON) {
            try self.decode(json)
        }
    }

    @Test("A file over the size cap is refused before decoding")
    func oversizedFileIsRefused() {
        let padding = String(repeating: " ", count: SQLFormatterRulesFile.maxSize)
        #expect(throws: SQLFormatterRulesError.tooLarge) {
            try self.decode("{}" + padding)
        }
    }

    // MARK: - Settings

    @Test("Default settings format exactly as the formatter did before it had settings")
    func defaultSettingsKeepOldOutput() {
        for keywordCase in [SQLKeywordCase.upper, .matchTypedElseUpper] {
            let resolved = SQLFormatterSettings.default.resolved(tabWidth: 4, editorKeywordCase: keywordCase)
            #expect(resolved == .default)
        }
    }

    @Test("Following the editor reads Tab width and Keyword case")
    func followsEditorSettings() {
        let settings = SQLFormatterSettings(indentFollowsTabWidth: true, keywordCaseFollowsEditor: true)
        let resolved = settings.resolved(tabWidth: 8, editorKeywordCase: .matchTypedElseLower)
        #expect(resolved.indentWidth == 8)
        #expect(resolved.keywordCase == .lower)
    }

    @Test("Imported rules follow nothing on this Mac")
    func importedRulesIgnoreEditorSettings() {
        let settings = SQLFormatterSettings(imported: Self.custom)
        #expect(settings.resolved(tabWidth: 8, editorKeywordCase: .upper) == Self.custom)
    }

    @Test("A rules file exported on one Mac formats identically on another")
    func exportedFileFormatsIdentically() throws {
        var rules = Self.custom
        rules.indentStyle = .spaces
        rules.lineWidth = 0
        var firstEditor = EditorSettings.default
        firstEditor.tabWidth = 8
        firstEditor.keywordCase = .upper
        let firstFormatter = SQLFormatterSettings(rules: rules, indentFollowsTabWidth: true, keywordCaseFollowsEditor: true)
        let first = firstFormatter.options(for: firstEditor)
        let file = try SQLFormatterRulesFile.encode(first)

        var secondEditor = EditorSettings.default
        secondEditor.tabWidth = 2
        secondEditor.keywordCase = .lower
        let second = SQLFormatterSettings(imported: try SQLFormatterRulesFile.decode(file)).options(for: secondEditor)

        let sql = "select u.id as user_id, count(o.id) as n from users u left join orders o on u.id = o.user_id "
            + "where u.status = 'active' and o.total > 10"
        let service = SQLFormatterService()
        let formattedFirst = try service.format(sql, dialect: .mysql, options: first).formattedSQL
        let formattedSecond = try service.format(sql, dialect: .mysql, options: second).formattedSQL
        #expect(formattedFirst == formattedSecond)
        #expect(formattedFirst.contains("\n        AND "))
        #expect(formattedFirst.hasPrefix("SELECT "))
    }

    @Test("Formatter settings sync as their own category, apart from the editor blob an older build rewrites")
    func formatterSyncsAsItsOwnCategory() {
        #expect(AppSettingsCategory.synced.contains(AppSettingsCategory.formatter))
        #expect(AppSettingsCategory.formatter != AppSettingsCategory.editor)
    }

    @Test("A Mac upgraded from a build that skipped formatter records fetches the zone once")
    func upgradeRefetchesSkippedFormatterRecords() throws {
        let pool = EphemeralDefaultsPool()
        let metadata = SyncMetadataStorage(userDefaults: try pool.make().defaults)
        var older = SyncCoordinator.readableContent
        older.remove(SyncCoordinator.formatterContentKind)
        _ = metadata.adoptReadableRecordTypes(older)
        #expect(metadata.adoptReadableRecordTypes(SyncCoordinator.readableContent))
        #expect(!metadata.adoptReadableRecordTypes(SyncCoordinator.readableContent))
    }

    @Test("Formatter settings persist under their own key and reset with the rest")
    func storageRoundTripAndReset() throws {
        let pool = EphemeralDefaultsPool()
        let storage = AppSettingsStorage(userDefaults: try pool.make().defaults)
        let custom = SQLFormatterSettings(imported: Self.custom)
        storage.saveFormatter(custom)
        #expect(storage.loadFormatter() == custom)
        storage.resetToDefaults()
        #expect(storage.loadFormatter() == .default)
    }

    @Test("Stored formatter settings with nothing in them decode to the defaults")
    func emptyStoredSettingsDecode() throws {
        #expect(try JSONDecoder().decode(SQLFormatterSettings.self, from: Data("{}".utf8)) == .default)
    }

    @Test("A stored formatter value this build cannot read costs only that field")
    func storedInvalidValueFallsBackAlone() throws {
        let json = #"{"commaPosition": "leading", "indentWidth": 99, "keywordCase": "title"}"#
        let settings = try JSONDecoder().decode(SQLFormatterSettings.self, from: Data(json.utf8))
        #expect(settings.rules.commaPosition == .leading)
        #expect(settings.rules.indentWidth == SQLFormatterOptions.default.indentWidth)
        #expect(settings.rules.keywordCase == SQLFormatterOptions.default.keywordCase)
    }

    @Test("Formatter settings round-trip with both follow choices")
    func settingsRoundTrip() throws {
        let settings = SQLFormatterSettings(rules: Self.custom, indentFollowsTabWidth: true, keywordCaseFollowsEditor: false)
        let decoded = try JSONDecoder().decode(SQLFormatterSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    // MARK: - Linked folder rules

    private final class Sandbox {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("SQLFormatterRulesTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        @discardableResult
        func write(_ relativePath: String, _ contents: String = "") throws -> URL {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
            return url
        }

        func folder(_ relativePath: String, isEnabled: Bool = true) -> LinkedSQLFolder {
            LinkedSQLFolder(path: root.appendingPathComponent(relativePath).path, isEnabled: isEnabled)
        }
    }

    @Test("The rules file at the linked folder's root applies to a file in a subfolder")
    func rootRulesApplyToSubfolders() throws {
        let sandbox = try Sandbox()
        let rules = try sandbox.write("queries/.sql-formatter.json", "{}")
        let file = try sandbox.write("queries/reports/daily.sql")
        let found = SQLFormatterRulesFile.url(forFileAt: file, in: [sandbox.folder("queries")])
        #expect(found?.resolvingSymlinksInPath() == rules.resolvingSymlinksInPath())
    }

    @Test("The rules file nearest the SQL file wins")
    func nearestRulesWin() throws {
        let sandbox = try Sandbox()
        try sandbox.write("queries/.sql-formatter.json", "{}")
        let nearer = try sandbox.write("queries/reports/.sql-formatter.json", "{}")
        let file = try sandbox.write("queries/reports/daily.sql")
        let found = SQLFormatterRulesFile.url(forFileAt: file, in: [sandbox.folder("queries")])
        #expect(found?.resolvingSymlinksInPath() == nearer.resolvingSymlinksInPath())
    }

    @Test("Nothing above the linked folder is read, and a disabled or unrelated folder gives no rules")
    func lookupStaysInsideEnabledFolder() throws {
        let sandbox = try Sandbox()
        try sandbox.write(".sql-formatter.json", "{}")
        let file = try sandbox.write("queries/daily.sql")
        let outside = try sandbox.write("elsewhere/other.sql")
        #expect(SQLFormatterRulesFile.url(forFileAt: file, in: [sandbox.folder("queries")]) == nil)
        try sandbox.write("queries/.sql-formatter.json", "{}")
        #expect(SQLFormatterRulesFile.url(forFileAt: file, in: [sandbox.folder("queries", isEnabled: false)]) == nil)
        #expect(SQLFormatterRulesFile.url(forFileAt: outside, in: [sandbox.folder("queries")]) == nil)
    }

    @Test("A file in a linked folder formats with the folder's rules, and other files with Settings")
    func ruleSourcePrefersFolderRules() throws {
        let sandbox = try Sandbox()
        try sandbox.write("queries/.sql-formatter.json", #"{"commaPosition": "leading"}"#)
        let file = try sandbox.write("queries/daily.sql")
        let folders = [sandbox.folder("queries")]
        var settings = SQLFormatterOptions.default
        settings.alignAliases = true

        let folderOptions = try SQLFormatterRuleSource.options(forFileAt: file, settings: settings, folders: folders)
        #expect(folderOptions.commaPosition == .leading)
        #expect(folderOptions.alignAliases == false)

        let scratch = try SQLFormatterRuleSource.options(forFileAt: nil, settings: settings, folders: folders)
        #expect(scratch == settings)
    }

    @Test("A rules file that is a symlink to a device is refused without reading it")
    func symlinkToDeviceIsRefused() throws {
        let sandbox = try Sandbox()
        let link = sandbox.root.appendingPathComponent(".sql-formatter.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        #expect(throws: SQLFormatterRulesError.self) {
            try SQLFormatterRulesFile.load(from: link)
        }
    }

    @Test("A rules file that is a symlink to a regular file is read")
    func symlinkToFileIsRead() throws {
        let sandbox = try Sandbox()
        let target = try sandbox.write("shared/rules.json", #"{"indentWidth": 4}"#)
        let link = sandbox.root.appendingPathComponent(".sql-formatter.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(try SQLFormatterRulesFile.load(from: link).indentWidth == 4)
    }

    @Test("An unreadable folder rules file refuses to format instead of using Settings")
    func unreadableFolderRulesThrow() throws {
        let sandbox = try Sandbox()
        try sandbox.write("queries/.sql-formatter.json", #"{"indentWidth": "wide"}"#)
        let file = try sandbox.write("queries/daily.sql")
        #expect(throws: SQLFormatterFolderRulesError.self) {
            try SQLFormatterRuleSource.options(
                forFileAt: file,
                settings: .default,
                folders: [sandbox.folder("queries")]
            )
        }
    }
}
