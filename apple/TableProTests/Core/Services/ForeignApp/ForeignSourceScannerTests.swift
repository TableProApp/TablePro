//
//  ForeignSourceScannerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ForeignSourceScannerTests {
    private let root: URL

    init() throws {
        root = try ForeignFixture.makeTempDirectory("ForeignSourceScannerTests")
    }

    // MARK: - Rule 0.3, shared with the core

    private struct SourceList: Decodable {
        let schemaVersion: Int
        let cases: [Case]

        struct Case: Decodable {
            let name: String
            let platform: String
            let rows: [Row]
            let ticked: [String]
            let preselected: String?
        }

        struct Row: Decodable {
            let app: String
            let availability: String
            let connections: Int
            let picksFile: Bool
        }
    }

    private static func sourceList(file: StaticString = #filePath) throws -> SourceList {
        var repository = URL(fileURLWithPath: "\(file)")
        for _ in 0..<6 {
            repository.deleteLastPathComponent()
        }
        let url = repository.appendingPathComponent("core/crates/foreign-import/tests/fixtures/source_list.json")
        return try JSONDecoder().decode(SourceList.self, from: Data(contentsOf: url))
    }

    private static func summary(_ row: SourceList.Row) throws -> ForeignSourceSummary {
        let availability: ForeignSourceAvailability
        switch row.availability {
        case "available": availability = .available
        case "notFound": availability = .notFound
        case "unreadable": availability = .unreadable(reason: "fixture")
        default: throw CocoaError(.coderInvalidValue)
        }
        return ForeignSourceSummary(id: row.app, availability: availability, connections: row.connections, picksFile: row.picksFile)
    }

    @Test("Every case of the core's source_list.json ticks and preselects the same rows here")
    func sourceListParity() throws {
        let list = try Self.sourceList()
        #expect(list.schemaVersion == 1)
        #expect(!list.cases.isEmpty)

        for testCase in list.cases {
            let rows = try testCase.rows.map(Self.summary)
            #expect(ForeignSourceRule.ticked(rows) == testCase.ticked, "\(testCase.name)")
            #expect(ForeignSourceRule.preselected(rows) == testCase.preselected, "\(testCase.name)")
        }
    }

    @Test("The source with the most connections is preselected; a tie keeps the earlier row")
    func preselectByCount() {
        let rows = [
            ForeignSourceSummary(id: "tableplus", availability: .available, connections: 0, picksFile: false),
            ForeignSourceSummary(id: "dbeaver", availability: .available, connections: 5, picksFile: false),
            ForeignSourceSummary(id: "datagrip", availability: .unreadable(reason: "x"), connections: 0, picksFile: false),
            ForeignSourceSummary(id: "beekeeperstudio", availability: .available, connections: 5, picksFile: false),
            ForeignSourceSummary(id: "navicat", availability: .available, connections: 0, picksFile: true),
        ]

        #expect(ForeignSourceRule.preselected(rows) == "dbeaver")
        #expect(ForeignSourceRule.ticked(rows) == ["dbeaver", "beekeeperstudio"])
        #expect(ForeignSourceRule.preselected(Array(rows.suffix(1))) == "navicat")
        #expect(ForeignSourceRule.preselected([rows[2]]) == nil)
    }

    // MARK: - Fixtures

    private static func appLookup(installed: Bool) -> @Sendable (String) -> URL? {
        { _ in installed ? URL(fileURLWithPath: "/Applications/Installed.app") : nil }
    }

    private func importers(installed: Set<String> = []) -> [any ForeignAppImporter] {
        var tablePlus = TablePlusImporter()
        tablePlus.dataDirectoryOverride = root.appendingPathComponent("TablePlus", isDirectory: true)
        tablePlus.readViewSetting = { _ in nil }
        tablePlus.resolveAppURL = Self.appLookup(installed: installed.contains("tableplus"))

        var sequelAce = SequelAceImporter()
        sequelAce.favoritesFileURL = root.appendingPathComponent("SequelAce/Favorites.plist")
        sequelAce.queryFavoritesFileURL = root.appendingPathComponent("SequelAce/com.sequel-ace.sequel-ace.plist")
        sequelAce.resolveAppURL = Self.appLookup(installed: installed.contains("sequelace"))

        var dbeaver = DBeaverImporter()
        dbeaver.dbeaverDataRoot = root.appendingPathComponent("DBeaverData", isDirectory: true)
        dbeaver.resolveAppURL = Self.appLookup(installed: installed.contains("dbeaver"))

        var dataGrip = DataGripImporter()
        dataGrip.jetBrainsRoot = root.appendingPathComponent("JetBrains", isDirectory: true)
        dataGrip.resolveAppURL = Self.appLookup(installed: installed.contains("datagrip"))

        var beekeeper = BeekeeperStudioImporter()
        beekeeper.dataDirectoryURL = root.appendingPathComponent("beekeeper-studio", isDirectory: true)
        beekeeper.resolveAppURL = Self.appLookup(installed: installed.contains("beekeeperstudio"))

        return [tablePlus, sequelAce, dbeaver, dataGrip, beekeeper, NavicatImporter()]
    }

    private func writeTablePlus(_ names: [String]) throws {
        let entries = names.enumerated().map { index, name in ["ConnectionName": name, "ID": "c\(index)", "Driver": "MySQL"] }
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
        try ForeignFixture.write("", to: root.appendingPathComponent("TablePlus/Connections.plist"))
        try data.write(to: root.appendingPathComponent("TablePlus/Connections.plist"))
    }

    private func writeDBeaver(connections: Int) throws {
        let entries = (0..<connections).reduce(into: [String: Any]()) { result, index in
            result["pg-\(index)"] = ["name": "PG \(index)", "provider": "postgresql", "configuration": ["host": "h"]] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: ["connections": entries])
        let file = root.appendingPathComponent("DBeaverData/workspace6/General/.dbeaver/data-sources.json")
        try ForeignFixture.write("", to: file)
        try data.write(to: file)
    }

    private func writeSequelAce() throws {
        let connection: [String: Any] = ["name": "DB", "id": 1]
        let favoritesRoot: [String: Any] = ["Name": "Favorites Root", "Children": [connection]]
        let favorites: [String: Any] = ["Favorites Root": favoritesRoot]
        let data = try PropertyListSerialization.data(fromPropertyList: favorites, format: .xml, options: 0)
        try ForeignFixture.write("", to: root.appendingPathComponent("SequelAce/Favorites.plist"))
        try data.write(to: root.appendingPathComponent("SequelAce/Favorites.plist"))
    }

    // MARK: - Launch probe

    @Test("The probe finds nothing on an empty Mac, and never lists a file-picked importer")
    func probeOnAnEmptyMac() async {
        #expect(await ForeignSourceScanner.probe(importers()).isEmpty)
    }

    @Test("The probe finds an installed app and one whose data outlived it")
    func probeFindsInstalledAppsAndLeftoverData() async throws {
        try writeTablePlus(["Orders"])
        try writeDBeaver(connections: 1)

        let found = await ForeignSourceScanner.probe(importers(installed: ["beekeeperstudio"]))

        #expect(found.map { $0.id } == ["tableplus", "dbeaver", "beekeeperstudio"])
        #expect(found.map { $0.displayName } == ["TablePlus", "DBeaver", "Beekeeper Studio"], "The guide names the apps it found")
    }

    @Test("The probe never reads Sequel Ace's container: only an installed app counts there")
    func probeLeavesTheContainerAlone() async throws {
        try writeSequelAce()

        #expect(await ForeignSourceScanner.probe(importers()).isEmpty)
        #expect(await ForeignSourceScanner.probe(importers(installed: ["sequelace"])).map { $0.id } == ["sequelace"])
    }

    // MARK: - Full scan

    @Test("The scan keeps registry order, counts what it reads and reads data without the app as available")
    func scanCountsAvailableSources() async throws {
        try writeTablePlus(["Orders", "Billing"])
        try writeDBeaver(connections: 3)

        let rows = await ForeignSourceScanner.scan(importers())

        #expect(rows.map { $0.id } == ["tableplus", "sequelace", "dbeaver", "datagrip", "beekeeperstudio", "navicat"])
        #expect(rows.map { $0.availability } == [.available, .notFound, .available, .notFound, .notFound, .available])
        #expect(rows.map { $0.inventory.connections } == [2, 0, 3, 0, 0, 0])
        #expect(rows.map { $0.picksFile } == [false, false, false, false, false, true])
        #expect(ForeignSourceRule.preselected(rows.map { $0.summary }) == "dbeaver")
        #expect(ForeignSourceRule.ticked(rows.map { $0.summary }) == ["tableplus", "dbeaver"])
    }

    @Test("Data that is there but cannot be read shows as unreadable with its reason, never as zero")
    func scanReportsUnreadableData() async throws {
        try ForeignFixture.write("not a property list", to: root.appendingPathComponent("TablePlus/Connections.plist"))

        let row = try #require(await ForeignSourceScanner.scan(importers()).first { $0.id == "tableplus" })

        guard case .unreadable(let reason) = row.availability else {
            Issue.record("Expected an unreadable source, got \(row.availability)")
            return
        }
        #expect(reason.contains("Connections.plist"))
        #expect(!ForeignSourceRule.ticked([row.summary]).contains("tableplus"))
    }

    // MARK: - Menu picker

    @Test("The menu picker preselects by rule 0.3 and scans once, so Back finds its toggles as left")
    @MainActor
    func pickerKeepsItsStateAcrossBack() async throws {
        try writeTablePlus(["Orders"])
        try writeDBeaver(connections: 4)
        let scans = ScanCounter()
        let sources = importers()
        let model = ForeignSourcePickerModel {
            await scans.record()
            return await ForeignSourceScanner.scan(sources)
        }

        await model.load()
        let selected = try #require(model.selectedRow)
        #expect(selected.id == "dbeaver")
        let tablePlus = try #require(model.rows.first { $0.id == "tableplus" })
        #expect(!model.request(for: tablePlus).includePasswords)
        model.setIncludePasswords(true, for: tablePlus)
        model.selectedId = tablePlus.id

        await model.load()

        #expect(await scans.count == 1)
        #expect(model.selectedId == "tableplus")
        #expect(model.request(for: tablePlus).includePasswords)
    }

    @Test("Saved queries start on only for a source that has some")
    func savedQueriesDefault() {
        let empty = ForeignSourceRow(
            importer: DBeaverImporter(),
            availability: .available,
            inventory: ForeignAppInventory(connections: 2, savedQueries: 0)
        )
        let withScripts = ForeignSourceRow(
            importer: DBeaverImporter(),
            availability: .available,
            inventory: ForeignAppInventory(connections: 2, savedQueries: 3)
        )
        let navicat = ForeignSourceRow(
            importer: NavicatImporter(),
            availability: .available,
            inventory: ForeignAppInventory(connections: 0, savedQueries: 0)
        )

        #expect(!ForeignSourcePickerModel.defaultRequest(for: empty).includeSavedQueries)
        #expect(ForeignSourcePickerModel.defaultRequest(for: withScripts).includeSavedQueries)
        #expect(!ForeignSourcePickerModel.defaultRequest(for: navicat).includeSavedQueries)
        #expect(ForeignSourcePickerModel.defaultRequest(for: navicat).includePasswords)
    }
}

private actor ScanCounter {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
