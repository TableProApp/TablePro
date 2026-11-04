//
//  DuckDBTrustBundleFile.swift
//  DuckDBDriverPlugin
//

import Foundation
import TableProDuckDBCore

/// The file `ca_cert_file` names for a Verify Identity connection with a CA, holding httpfs's default
/// bundle and the chosen CA (`QuackTrustBundle.combined`).
///
/// It stays for the life of the connection. httpfs caches a bundle by path, but starts a new cache when
/// its HTTP client setting changes, which the editor can do, and then reads the file again. It goes in the
/// temporary directory because it holds certificates only, never a key: a copy a crash leaves behind
/// exposes nothing, and the system clears it.
final class DuckDBTrustBundleFile: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?

    func write(caCertificatePath: String) throws -> String {
        let path = NSString(string: caCertificatePath).expandingTildeInPath
        let caCertificate: Data
        do {
            caCertificate = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw QuackConnectError.caCertificateUnreadable(path: path, reason: error.localizedDescription)
        }
        let defaultBundle = QuackTrustBundle.defaultBundleLocations.lazy
            .compactMap { FileManager.default.contents(atPath: $0) }
            .first
        let bundle = try QuackTrustBundle.combined(
            defaultBundle: defaultBundle,
            caCertificate: caCertificate,
            caCertificatePath: path
        )
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("TablePro-DuckDB-CA-\(UUID().uuidString).pem")
        do {
            try bundle.write(to: target, options: .atomic)
        } catch {
            throw QuackConnectError.trustBundleUnwritable(reason: error.localizedDescription)
        }
        let previous = lock.withLock { () -> URL? in
            let previous = url
            url = target
            return previous
        }
        if let previous { try? FileManager.default.removeItem(at: previous) }
        return target.path
    }

    /// Hands the file over, for a caller that removes it once the DuckDB instance reading it is closed.
    func take() -> URL? {
        lock.withLock { () -> URL? in
            let current = url
            url = nil
            return current
        }
    }

    func remove() {
        guard let url = take() else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
