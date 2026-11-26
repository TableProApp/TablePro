import Foundation
@testable import TablePro
import TableProFFI

// A folder of its own for each test's stores and the core's history.db beside them.
final class CoreMirrorFixture {
    let directory: URL
    let core: CoreHistoryDatabase
    let pool = EphemeralDefaultsPool()

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreMirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        core = CoreHistoryDatabase(folder: directory.appendingPathComponent("Core", isDirectory: true), clientVersion: "test")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }
}

extension Array where Element == String {
    var uuids: Set<UUID> {
        Set(compactMap(UUID.init(uuidString:)))
    }
}
