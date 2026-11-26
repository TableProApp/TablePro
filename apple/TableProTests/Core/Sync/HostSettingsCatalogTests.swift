import Foundation
@testable import TablePro
import Testing

@MainActor
private final class FakeSettingsStores: HostSettingsStores {
    var held: [String: Data] = [:]
    // What a write keeps of a document, as a build that drops what it cannot read; nil writes nothing.
    var keeps: (String, Data) -> Data? = { _, data in data }
    var failsRemoval = false

    func documents() -> [String: Data] {
        held
    }

    func document(for category: String) -> Data? {
        held[category]
    }

    func write(_ document: Data, for category: String) -> HostSettingsWrite {
        guard HostSettingsCategoryKind(category) != .unknown, let written = keeps(category, document) else {
            return .unreadable
        }
        held[category] = written
        return .written
    }

    func remove(_ category: String) throws {
        if failsRemoval {
            throw HostSettingsStoreError.unwritable(category)
        }
        held[category] = nil
    }
}

private func data(_ text: String) -> Data {
    Data(text.utf8)
}

private func dropping(_ key: String) -> (String, Data) -> Data? {
    { _, document in
        guard var object = (try? JSONSerialization.jsonObject(with: document)) as? [String: Any] else { return document }
        object[key] = nil
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

@MainActor
struct HostSettingsCatalogTests {
    private let directory: URL
    private let keptFile: JSONFileStore<HostSettingsKept>

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostSettingsCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        keptFile = JSONFileStore(url: directory.appendingPathComponent("kept.json"))
    }

    private func catalog(_ stores: FakeSettingsStores, build: String = "1") -> HostSettingsCatalog {
        HostSettingsCatalog(stores: stores, keptFile: keptFile, build: build)
    }

    private func reported(_ catalog: HostSettingsCatalog) throws -> [String: String] {
        try catalog.categories().mapValues { String(decoding: $0, as: UTF8.self) }
    }

    @Test("A category no store here names comes back from categories unchanged")
    func unknownCategoryComesBack() throws {
        let stores = FakeSettingsStores()
        stores.held["tabs"] = data(#"{"enablePreviewTabs":true}"#)
        let catalog = catalog(stores)

        try catalog.apply("newerCategory", document: data(#"{"option":[1,2]}"#))

        #expect(try reported(catalog) == [
            "tabs": #"{"enablePreviewTabs":true}"#,
            "newerCategory": #"{"option":[1,2]}"#,
        ])
    }

    @Test("An option this build drops on a pull goes back as sent, so the pass finds no edit")
    func droppedOptionGoesBack() throws {
        let stores = FakeSettingsStores()
        stores.keeps = dropping("newerOption")
        let catalog = catalog(stores)

        try catalog.apply("editor", document: data(#"{"newerOption":"x","tabWidth":8}"#))

        #expect(stores.held["editor"] == data(#"{"tabWidth":8}"#))
        #expect(try reported(catalog)["editor"] == #"{"newerOption":"x","tabWidth":8}"#)
    }

    @Test("A local edit of a kept option sends this Mac's value")
    func localEditEndsTheKeptOption() throws {
        let stores = FakeSettingsStores()
        stores.keeps = { _, _ in data(#"{"tabWidth":4}"#) }
        let catalog = catalog(stores)
        try catalog.apply("editor", document: data(#"{"tabWidth":99}"#))

        stores.held["editor"] = data(#"{"tabWidth":2}"#)

        #expect(try reported(catalog)["editor"] == #"{"tabWidth":2}"#)
        #expect(!keptFile.exists)
    }

    @Test("A deleted theme is removed and nothing of it is kept")
    func deletedThemeIsRemoved() throws {
        let stores = FakeSettingsStores()
        stores.keeps = { _, _ in nil }
        let catalog = catalog(stores)
        try catalog.apply("theme.ocean", document: data(#"{"schema":99}"#))
        #expect(try reported(catalog)["theme.ocean"] == #"{"schema":99}"#)

        try catalog.apply("theme.ocean", document: nil)

        #expect(try reported(catalog)["theme.ocean"] == nil)
    }

    @Test("A removal the store refused fails the call, so the engine tries again")
    func refusedRemovalThrows() {
        let stores = FakeSettingsStores()
        stores.held["theme.ocean"] = data("{}")
        stores.failsRemoval = true

        #expect(throws: HostSettingsStoreError.self) {
            try catalog(stores).apply("theme.ocean", document: nil)
        }
    }

    @Test("What was kept survives a relaunch")
    func keptSurvivesARelaunch() throws {
        let stores = FakeSettingsStores()
        try catalog(stores).apply("newerCategory", document: data(#"{"a":1}"#))

        #expect(try reported(catalog(stores))["newerCategory"] == #"{"a":1}"#)
    }

    @Test("An unreadable kept file fails the read rather than reporting its categories as deleted")
    func unreadableKeptFileThrows() throws {
        try data("not json").write(to: keptFile.url)

        #expect(throws: (any Error).self) {
            try catalog(FakeSettingsStores()).categories()
        }
    }

    @Test("A newer build offers what an older one kept to its stores, and keeps nothing it now reads")
    func newerBuildReadsWhatWasKept() throws {
        let stores = FakeSettingsStores()
        stores.keeps = dropping("newerOption")
        try catalog(stores, build: "1").apply("editor", document: data(#"{"newerOption":"x","tabWidth":8}"#))

        stores.keeps = { _, document in document }
        let reported = try reported(catalog(stores, build: "2"))

        #expect(stores.held["editor"] == data(#"{"newerOption":"x","tabWidth":8}"#))
        #expect(reported["editor"] == #"{"newerOption":"x","tabWidth":8}"#)
        #expect(!keptFile.exists)
    }

    @Test("The same build does not offer the kept values again")
    func sameBuildDoesNotRetry() throws {
        let stores = FakeSettingsStores()
        stores.keeps = dropping("newerOption")
        try catalog(stores, build: "1").apply("editor", document: data(#"{"newerOption":"x","tabWidth":8}"#))
        var writes = 0
        stores.keeps = { _, document in
            writes += 1
            return document
        }

        _ = try catalog(stores, build: "1").categories()

        #expect(writes == 0)
    }
}
