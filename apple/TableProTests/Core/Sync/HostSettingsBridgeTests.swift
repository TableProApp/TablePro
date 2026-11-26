import Foundation
@testable import TablePro
import TableProFFI
import Testing

@MainActor
private final class RecordingStores: HostSettingsStores {
    var held: [String: Data] = ["tabs": Data(#"{"enablePreviewTabs":false}"#.utf8)]
    var failsReads = false
    private(set) var writesOnMainThread: [Bool] = []

    func documents() throws -> [String: Data] {
        if failsReads {
            throw HostSettingsStoreError.unreadable("tabs")
        }
        return held
    }

    func document(for category: String) -> Data? {
        held[category]
    }

    func write(_ document: Data, for category: String) -> HostSettingsWrite {
        writesOnMainThread.append(Thread.isMainThread)
        held[category] = document
        return .written
    }

    func remove(_ category: String) {
        held[category] = nil
    }
}

@MainActor
struct HostSettingsBridgeTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HostSettingsBridgeTests-\(UUID().uuidString)", isDirectory: true)

    private func bridge(_ stores: RecordingStores) -> HostSettingsBridge {
        HostSettingsBridge(catalog: HostSettingsCatalog(
            stores: stores,
            keptFile: JSONFileStore(url: directory.appendingPathComponent("kept.json")),
            build: "1"
        ))
    }

    @Test("The core's blocking thread reads and writes the stores on the main thread")
    func callsFromABlockingThreadReachTheMainThread() async throws {
        let stores = RecordingStores()
        let bridge = bridge(stores)

        let categories = try await Task.detached { try bridge.categories() }.value
        try await Task.detached { try bridge.apply(category: "editor", document: #"{"tabWidth":2}"#) }.value

        #expect(categories == [SettingsCategoryArg(category: "tabs", document: #"{"enablePreviewTabs":false}"#)])
        #expect(stores.writesOnMainThread == [true])
        #expect(stores.held["editor"] == Data(#"{"tabWidth":2}"#.utf8))
    }

    @Test("A store that cannot be read fails the call with a detail that names no category")
    func failuresReachTheCoreAsHostErrors() async {
        let stores = RecordingStores()
        stores.failsReads = true
        let bridge = bridge(stores)

        let failure = await Task.detached { () -> HostSecretError? in
            do {
                _ = try bridge.categories()
                return nil
            } catch {
                return error as? HostSecretError
            }
        }.value

        #expect(failure == .Failed(detail: "the settings stores could not read a category"))
    }
}
