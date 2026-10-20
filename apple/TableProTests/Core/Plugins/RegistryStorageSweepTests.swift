import Foundation
@testable import TablePro
import Testing

struct RegistryStorageSweepTests {
    private let fileManager = FileManager.default

    private func withBase(_ body: (URL) throws -> Void) throws {
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("RegistryStorageSweepTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }
        try body(base)
    }

    private func touch(_ url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    @Test("The registry cache under Application Support opens at the file-system path")
    func cacheOpensAtTheFileSystemPath() throws {
        try withBase { base in
            let directory = RegistryClient.cacheDirectory(
                in: base.appendingPathComponent("Application Support/TablePro", isDirectory: true)
            )
            let cache = RegistryClient.makeCache(at: directory)
            _ = cache.currentDiskUsage

            #expect(exists(directory.appendingPathComponent("Cache.db")))
            #expect(!exists(base.appendingPathComponent("Application%20Support")))
        }
    }

    @Test("A misplaced cache goes, with every encoded parent it left empty")
    func removesTheMisplacedCacheAndItsEmptyParents() throws {
        try withBase { base in
            let directory = RegistryClient.cacheDirectory(
                in: base.appendingPathComponent("Application Support/TablePro", isDirectory: true)
            )
            try touch(directory.appendingPathComponent("Cache.db"))
            let encodedRoot = base.appendingPathComponent("Application%20Support", isDirectory: true)
            try touch(encodedRoot.appendingPathComponent("TablePro/Registry/URLCache/Cache.db"))
            try touch(encodedRoot.appendingPathComponent("TablePro/.DS_Store"))

            RegistryStorageSweep.removeMisplacedCache(for: directory)

            #expect(!exists(encodedRoot))
            #expect(exists(directory.appendingPathComponent("Cache.db")))
            #expect(exists(base))
        }
    }

    @Test("An encoded parent holding anything else stays")
    func keepsAnEncodedParentThatHoldsOtherFiles() throws {
        try withBase { base in
            let directory = RegistryClient.cacheDirectory(
                in: base.appendingPathComponent("Application Support/TablePro", isDirectory: true)
            )
            let encodedRoot = base.appendingPathComponent("Application%20Support", isDirectory: true)
            try touch(encodedRoot.appendingPathComponent("TablePro/Registry/URLCache/Cache.db"))
            try touch(encodedRoot.appendingPathComponent("OtherApp/Cache.db"))

            RegistryStorageSweep.removeMisplacedCache(for: directory)

            #expect(!exists(encodedRoot.appendingPathComponent("TablePro")))
            #expect(exists(encodedRoot.appendingPathComponent("OtherApp/Cache.db")))
        }
    }

    @Test("A cache whose path has nothing to encode is the real one and stays")
    func keepsACacheWhosePathHasNothingToEncode() throws {
        try withBase { base in
            let directory = RegistryClient.cacheDirectory(in: base.appendingPathComponent("Support/TablePro", isDirectory: true))
            try touch(directory.appendingPathComponent("Cache.db"))

            RegistryStorageSweep.removeMisplacedCache(for: directory)

            #expect(exists(directory.appendingPathComponent("Cache.db")))
        }
    }

    @Test("The manifest files and defaults keys older builds wrote go; the cache and other keys stay")
    func removesRetiredManifestsAndKeys() throws {
        try withBase { base in
            let support = base.appendingPathComponent("Support/TablePro", isDirectory: true)
            let caches = base.appendingPathComponent("Caches/com.TablePro", isDirectory: true)
            let cacheDatabase = RegistryClient.cacheDirectory(in: support).appendingPathComponent("Cache.db")
            try touch(support.appendingPathComponent("Registry/registry-manifest.json"))
            try touch(cacheDatabase)
            try touch(caches.appendingPathComponent("registry-manifest.json"))
            try touch(caches.appendingPathComponent("Cache.db"))
            let suite = try EphemeralDefaults()
            for key in ["com.TablePro.registryLastFetch", "com.TablePro.customRegistryURL", "registryManifestCache"] {
                suite.defaults.set("x", forKey: key)
            }
            suite.defaults.set("x", forKey: "com.TablePro.unrelated")

            RegistryStorageSweep.sweep(supportDirectory: support, legacyCachesDirectory: caches, defaults: suite.defaults)

            #expect(!exists(support.appendingPathComponent("Registry/registry-manifest.json")))
            #expect(!exists(caches.appendingPathComponent("registry-manifest.json")))
            #expect(exists(cacheDatabase))
            #expect(exists(caches.appendingPathComponent("Cache.db")))
            #expect(suite.defaults.object(forKey: "com.TablePro.registryLastFetch") == nil)
            #expect(suite.defaults.object(forKey: "com.TablePro.customRegistryURL") == nil)
            #expect(suite.defaults.object(forKey: "registryManifestCache") == nil)
            #expect(suite.defaults.string(forKey: "com.TablePro.unrelated") == "x")
        }
    }
}
