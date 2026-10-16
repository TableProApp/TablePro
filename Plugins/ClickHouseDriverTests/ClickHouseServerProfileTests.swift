//
//  ClickHouseServerProfileTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

extension ClickHouseServerProfile {
    static func testing(
        version: String? = nil,
        writableSettings: Set<ClickHouseURLSetting> = [],
        catalog: Set<ClickHouseCatalogFeature> = Set(ClickHouseCatalogFeature.allCases)
    ) -> ClickHouseServerProfile {
        ClickHouseServerProfile(
            version: version.flatMap(ClickHouseServerVersion.init),
            writableSettings: writableSettings,
            catalog: catalog
        )
    }
}

/// `system.settings` rows as the servers answered them, the columns cut to the ones the profile
/// reads plus a neighbour, in the order each version lists them.
enum ClickHouseSettingsRows {
    static let columns20 = ["name", "value", "changed", "description", "min", "max", "readonly"]

    static func rows(_ names: [ClickHouseURLSetting], readonly: String = "0") -> [[PluginCellValue]] {
        names.map { [.text($0.rawValue), .text("0"), .text("0"), .text(""), .null, .null, .text(readonly)] }
    }

    /// 23.8.8.20 and Altinity 23.8.8.21: no `http_write_exception_in_output_format` row.
    static let server2388 = rows(ClickHouseURLSetting.allCases.filter { $0 != .httpWriteExceptionInOutputFormat })
    static let server258 = rows(ClickHouseURLSetting.allCases)
    static let readonlyUser = rows(ClickHouseURLSetting.allCases, readonly: "1")
}

struct ClickHouseServerProfileTests {
    @Test(
        "version() parses on official, Cloud and Altinity builds",
        arguments: [
            ("23.8.8.20", [23, 8, 8, 20]),
            ("24.6.1.4472", [24, 6, 1, 4_472]),
            ("24.8.14.10548.altinitystable", [24, 8, 14, 10_548]),
            ("25.8.33.20002.altinityantalya", [25, 8, 33, 20_002]),
            ("23.9\n", [23, 9]),
        ]
    )
    func versionParses(text: String, components: [Int]) {
        #expect(ClickHouseServerVersion(text)?.components == components)
    }

    @Test("A version string with no leading number is no version", arguments: ["", "garbage", "v23.8"])
    func garbageVersionIsNil(text: String) {
        #expect(ClickHouseServerVersion(text) == nil)
    }

    @Test(
        "MODIFY COMMENT is offered from 23.9, where it works on ReplicatedMergeTree",
        arguments: [
            ("21.11.11.1", false),
            ("23.8.16.16", false),
            ("23.8.8.21.altinitystable", false),
            ("23.9.6.20", true),
            ("24.8.14.10548.altinitystable", true),
            ("26.3.52.9", true),
        ]
    )
    func modifyCommentGate(version: String, expected: Bool) {
        #expect(ClickHouseServerProfile.testing(version: version).hasModifyComment == expected)
    }

    @Test("An unknown version gets no MODIFY COMMENT")
    func unknownVersionHasNoModifyComment() {
        #expect(!ClickHouseServerProfile.testing().hasModifyComment)
        #expect(!ClickHouseServerProfile.bootstrap.hasModifyComment)
    }

    @Test("23.8.8.20 lists no write-exception setting, so the driver never sends it there")
    func server2388HasNoWriteExceptionSetting() {
        let settings = ClickHouseServerProfile.writableSettings(
            columns: ClickHouseSettingsRows.columns20,
            rows: ClickHouseSettingsRows.server2388
        )
        let profile = ClickHouseServerProfile.testing(version: "23.8.8.20", writableSettings: settings)
        #expect(profile.queryItem(.httpWriteExceptionInOutputFormat, "0") == nil)
        #expect(profile.queryItem(.sendProgressInHTTPHeaders, "1") != nil)
    }

    @Test("A server that lists the setting gets it")
    func server258SendsWriteExceptionSetting() {
        let settings = ClickHouseServerProfile.writableSettings(
            columns: ClickHouseSettingsRows.columns20,
            rows: ClickHouseSettingsRows.server258
        )
        #expect(settings == Set(ClickHouseURLSetting.allCases))
    }

    @Test("A setting read-only for this user is never sent")
    func readonlyUserGetsNoOptionalSetting() {
        let settings = ClickHouseServerProfile.writableSettings(
            columns: ClickHouseSettingsRows.columns20,
            rows: ClickHouseSettingsRows.readonlyUser
        )
        #expect(settings.isEmpty)
    }

    @Test("19.16 has no readonly column, so the user's readonly setting decides", arguments: ["0", "2"])
    func serverWithoutReadonlyColumn(readonly: String) {
        let columns = ["name", "value", "changed", "description"]
        let rows: [[PluginCellValue]] = [
            [.text("send_progress_in_http_headers"), .text("0"), .text("0"), .text("")],
            [.text("max_result_rows"), .text("0"), .text("0"), .text("")],
            [.text("readonly"), .text(readonly), .text("0"), .text("")],
        ]
        #expect(ClickHouseServerProfile.writableSettings(columns: columns, rows: rows)
            == [.sendProgressInHTTPHeaders, .maxResultRows])
    }

    @Test("readonly = 1 on 19.16 makes every setting unchangeable")
    func readonlyUserWithoutReadonlyColumn() {
        let columns = ["name", "value", "changed", "description"]
        let rows: [[PluginCellValue]] = [
            [.text("send_progress_in_http_headers"), .text("0"), .text("0"), .text("")],
            [.text("readonly"), .text("1"), .text("1"), .text("")],
        ]
        #expect(ClickHouseServerProfile.writableSettings(columns: columns, rows: rows).isEmpty)
    }

    @Test("A settings answer with no name column yields nothing")
    func settingsWithoutNameColumn() {
        #expect(ClickHouseServerProfile.writableSettings(columns: ["value"], rows: [[.text("0")]]).isEmpty)
    }

    @Test("A settings constraint's min, max and disallowed values are read from the row")
    func constraintsAreRead() {
        let columns = ["name", "value", "changed", "description", "min", "max", "disallowed_values", "readonly"]
        let rows: [[PluginCellValue]] = [
            [.text("http_write_exception_in_output_format"), .text("1"), .text("0"), .text(""), .text("1"), .null, .text("[]"), .text("0")],
            [.text("max_result_rows"), .text("0"), .text("0"), .text(""), .null, .text("50"), .text("[]"), .text("0")],
            [.text("result_overflow_mode"), .text("throw"), .text("0"), .text(""), .null, .null, .text("['break']"), .text("0")],
            [.text("send_progress_in_http_headers"), .text("0"), .text("0"), .text(""), .null, .null, .text("[]"), .text("0")],
        ]
        let profile = ClickHouseServerProfile(
            version: nil,
            settingLimits: ClickHouseServerProfile.settingLimits(columns: columns, rows: rows),
            catalog: []
        )
        #expect(profile.queryItem(.httpWriteExceptionInOutputFormat, "0") == nil)
        #expect(profile.queryItem(.maxResultRows, "51") == nil)
        #expect(profile.queryItem(.maxResultRows, "50") != nil)
        #expect(profile.queryItem(.resultOverflowMode, "break") == nil)
        #expect(profile.queryItem(.sendProgressInHTTPHeaders, "1") != nil)
    }

    @Test("A Boolean bound written as true or false compares with 0 and 1")
    func booleanBounds() {
        #expect(!ClickHouseSettingLimits(min: "true", max: nil, disallowedValues: nil).allows("0"))
        #expect(ClickHouseSettingLimits(min: "true", max: nil, disallowedValues: nil).allows("1"))
        #expect(!ClickHouseSettingLimits(min: nil, max: nil, disallowedValues: "['false']").allows("0"))
    }

    /// The catalog probe's one row as each server answered it, in `ClickHouseCatalogFeature` order:
    /// comment, as_select, total_rows, total_bytes, origin, create_query, skipping-index table.
    @Test(
        "The catalog probe row maps to features as the servers answered",
        arguments: [
            (["0", "0", "0", "0", "0", "0", "0"], Set<ClickHouseCatalogFeature>()),
            (["1", "0", "1", "1", "0", "0", "1"], [.tablesComment, .tablesTotalRows, .tablesTotalBytes, .dataSkippingIndices]),
            (["1", "1", "1", "1", "1", "1", "1"], Set(ClickHouseCatalogFeature.allCases)),
            (["1", "1", "1", "1", "1", "1", "0"], Set(ClickHouseCatalogFeature.allCases).subtracting([.dataSkippingIndices])),
        ] as [([String], Set<ClickHouseCatalogFeature>)]
    )
    func catalogRow(answer: [String], expected: Set<ClickHouseCatalogFeature>) {
        #expect(ClickHouseServerProfile.catalog(row: answer.map { .text($0) }) == expected)
    }

    @Test("A null count reads as absent")
    func nullCatalogCountIsAbsent() {
        let row: [PluginCellValue] = [.text("1"), .text("1"), .text("1"), .text("1"), .text("1"), .text("1"), .null]
        #expect(!ClickHouseServerProfile.testing(catalog: ClickHouseServerProfile.catalog(row: row)).hasDataSkippingIndices)
    }

    @Test("A settings probe that cannot be read sends nothing optional; a catalog one asks for everything")
    func failedProbesFallBack() {
        let profile = ClickHouseServerProfile(versionText: "23.8.8.20", settings: nil, catalogRow: nil)
        #expect(profile.writableSettings.isEmpty)
        #expect(profile.catalog == Set(ClickHouseCatalogFeature.allCases))
        #expect(profile.version?.components == [23, 8, 8, 20])
    }

    @Test("Before the probes answer nothing optional is sent")
    func bootstrapSendsNothingOptional() {
        #expect(ClickHouseServerProfile.bootstrap.writableSettings.isEmpty)
    }

    @Test("The probes ask for every setting and catalog feature the profile reads, in order")
    func probeQueriesNameEverything() {
        for setting in ClickHouseURLSetting.allCases {
            #expect(ClickHouseServerProfile.settingsProbeQuery.contains("'\(setting.rawValue)'"))
        }
        #expect(ClickHouseServerProfile.settingsProbeQuery.contains("'readonly'"))
        let aliases = ClickHouseCatalogFeature.allCases.map { " AS \($0.rawValue)" }
        let positions = aliases.compactMap { ClickHouseServerProfile.catalogProbeQuery.range(of: $0)?.lowerBound }
        #expect(positions.count == aliases.count)
        #expect(positions == positions.sorted())
    }
}
