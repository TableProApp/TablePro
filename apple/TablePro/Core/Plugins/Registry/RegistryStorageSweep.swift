import Foundation
import os

// Removes plugin registry storage that nothing reads any more. Every check is one stat or one
// defaults lookup, so it runs on each launch rather than tracking whether it already ran.
internal enum RegistryStorageSweep {
    private static let logger = Logger(subsystem: "com.TablePro", category: "RegistryClient")

    // 0.81 and earlier kept the manifest, its fetch date and an override URL here; URLCache holds
    // the manifest now. The unprefixed keys predate 0.40, whose launch migration 0.82 dropped.
    private static let retiredDefaultsKeys = [
        "com.TablePro.registryLastFetch",
        "com.TablePro.customRegistryURL",
        "com.TablePro.lastRegistryURL",
        "com.TablePro.registryETag",
        "registryETag",
        "registryLastFetch",
        "registryManifestCache",
    ]

    private static let retiredManifestFileName = "registry-manifest.json"

    internal static func sweepProductionStorage() {
        let environment = AppStorageEnvironment.shared
        let legacyCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.TablePro", isDirectory: true)
        sweep(supportDirectory: environment.supportDirectory, legacyCachesDirectory: legacyCaches, defaults: environment.defaults)
    }

    internal static func sweep(
        supportDirectory: URL,
        legacyCachesDirectory: URL?,
        defaults: UserDefaults,
        fileManager: FileManager = .default
    ) {
        removeMisplacedCache(for: RegistryClient.cacheDirectory(in: supportDirectory), fileManager: fileManager)

        var manifests = [supportDirectory.appendingPathComponent("Registry/\(retiredManifestFileName)")]
        if let legacyCachesDirectory {
            manifests.append(legacyCachesDirectory.appendingPathComponent(retiredManifestFileName))
        }
        for manifest in manifests where fileManager.fileExists(atPath: manifest.path) {
            remove(manifest, fileManager)
        }

        for key in retiredDefaultsKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }

    // The cache the directory: initializer opened at the percent-encoded path, then each parent that
    // only exists because of it. An ancestor of the real path is never touched.
    internal static func removeMisplacedCache(for cacheDirectory: URL, fileManager: FileManager = .default) {
        let realPath = cacheDirectory.standardizedFileURL.path
        let misplaced = URL(fileURLWithPath: cacheDirectory.path(percentEncoded: true), isDirectory: true)
            .standardizedFileURL
        guard misplaced.path != realPath, fileManager.fileExists(atPath: misplaced.path) else { return }
        guard remove(misplaced, fileManager) else { return }

        var parent = misplaced.deletingLastPathComponent()
        while !isAncestor(parent.path, of: realPath), removeIfEmpty(parent, fileManager) {
            parent = parent.deletingLastPathComponent()
        }
    }

    private static func isAncestor(_ directory: String, of path: String) -> Bool {
        directory == "/" || path.hasPrefix(directory + "/")
    }

    // Finder leaves a .DS_Store in any folder someone opened to look at the stray tree.
    private static func removeIfEmpty(_ directory: URL, _ fileManager: FileManager) -> Bool {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path),
              entries.allSatisfy({ $0 == ".DS_Store" })
        else { return false }
        return remove(directory, fileManager)
    }

    @discardableResult
    private static func remove(_ url: URL, _ fileManager: FileManager) -> Bool {
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            logger.warning("Could not remove retired registry storage: \(error.publicLogShape, privacy: .public)")
            return false
        }
    }
}
