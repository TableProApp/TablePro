import Foundation
import TableProModels
import TableProPluginKit
import TableProQuery

// D1 is reached over HTTPS to Cloudflare's API, so there is no host on the local network to ask permission for. Its
// plugin writes no rows of its own, so edits take SQLBuilder's SQLite statements.
nonisolated final class CloudflareD1BackedDriver: PluginBackedDriver, @unchecked Sendable {
    private let d1: CloudflareD1PluginDriver

    // No `cancelsRunningRequest`: the plugin's cancel stops every request in flight, catalog reads included. Stop
    // cancels the run's own URL task instead.
    init(d1: CloudflareD1PluginDriver, queryTimeoutSeconds: Int? = nil) {
        self.d1 = d1
        super.init(
            plugin: d1,
            dialedHosts: [],
            queryTimeoutSeconds: queryTimeoutSeconds,
            readsOnly: { !SQLWriteClassifier.isWriteQuery($0, databaseType: .cloudflareD1) }
        )
    }

    // A connection may name its database by UUID, and the picker lists names, so the session reports the name the
    // plugin resolved, which follows every switch.
    override var currentDatabase: String? {
        d1.resolvedDatabaseName
    }

    // No D1 statement moves the client to another database, so it is always where the picker put it. The switch back
    // the base class makes after a MongoDB `use` would, during a picker switch, send the client back to the old one.
    override func inSessionDatabase<T: Sendable>(_ request: () async throws -> T) async throws -> T {
        try await request()
    }
}
