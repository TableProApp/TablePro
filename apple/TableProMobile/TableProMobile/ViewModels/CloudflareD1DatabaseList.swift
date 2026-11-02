import Foundation
import os
import TableProLogRedaction

// Another Account ID or token is another account's list, so a change of either loads again.
nonisolated struct CloudflareD1Credentials: Hashable, Sendable {
    let accountId: String
    let apiToken: String

    var isComplete: Bool {
        !accountId.isEmpty && !apiToken.isEmpty
    }
}

@MainActor
@Observable
final class CloudflareD1DatabaseList {
    typealias Loader = @Sendable (_ accountId: String, _ apiToken: String) async throws -> [D1DatabaseInfo]

    enum State {
        case idle
        case loading
        case loaded([D1DatabaseInfo])
        case failed(String)
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "CloudflareD1DatabaseList")

    private(set) var state: State = .idle
    // A refresh that fails keeps the list it refreshed, so its error is reported beside that list.
    private(set) var refreshError: String?
    @ObservationIgnored private var loadedCredentials: CloudflareD1Credentials?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let loader: Loader

    init(loader: @escaping Loader = { accountId, apiToken in
        try await CloudflareD1PluginDriver.listDatabases(accountId: accountId, apiToken: apiToken)
    }) {
        self.loader = loader
    }

    var databases: [D1DatabaseInfo] {
        guard case .loaded(let databases) = state else { return [] }
        return databases
    }

    // Each list is a request against the API quota the Mac shares, so a list these credentials
    // already fetched is kept. A fetch the picker cancelled by leaving counts as not done.
    func load(_ credentials: CloudflareD1Credentials) async {
        if loadedCredentials == credentials, holdsList { return }
        await fetch(credentials)
    }

    func refresh(_ credentials: CloudflareD1Credentials) async {
        await fetch(credentials)
    }

    func databases(matching query: String) -> [D1DatabaseInfo] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return databases }
        return databases.filter { $0.name.localizedStandardContains(term) || $0.uuid.localizedStandardContains(term) }
    }

    func listedDatabase(_ reference: String) -> D1DatabaseInfo? {
        let term = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        return databases.first { Self.reference(term, names: $0) }
    }

    // A typed value is still offered when the list failed or cannot see the database yet.
    func typedDatabase(in query: String) -> String? {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isDatabaseReference(term), listedDatabase(term) == nil else { return nil }
        return term
    }

    // A Mac connection may store the database's UUID where iOS stores its name.
    nonisolated static func reference(_ value: String, names database: D1DatabaseInfo) -> Bool {
        database.name == value || database.uuid.caseInsensitiveCompare(value) == .orderedSame
    }

    // The plugin opens a database by its UUID or by a name in Cloudflare's pattern, ^[a-zA-Z0-9][a-zA-Z0-9_-]*$.
    nonisolated static func isDatabaseReference(_ text: String) -> Bool {
        if UUID(uuidString: text) != nil { return true }
        guard let first = text.unicodeScalars.first, isASCIIAlphanumeric(first) else { return false }
        return text.unicodeScalars.allSatisfy { isASCIIAlphanumeric($0) || $0 == "_" || $0 == "-" }
    }

    nonisolated private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
    }

    private func fetch(_ credentials: CloudflareD1Credentials) async {
        generation += 1
        let attempt = generation
        guard credentials.isComplete else {
            loadedCredentials = nil
            state = .idle
            refreshError = nil
            return
        }
        let refreshing = loadedCredentials == credentials && holdsList
        if !refreshing {
            loadedCredentials = nil
            state = .loading
            refreshError = nil
        }
        do {
            let fetched = try await loader(credentials.accountId, credentials.apiToken)
            guard attempt == generation else { return }
            loadedCredentials = credentials
            state = .loaded(fetched.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            refreshError = nil
        } catch {
            guard attempt == generation else { return }
            // The picker left or the credentials changed: not a failure, and the next visit loads again.
            if Task.isCancelled || Self.isCancellation(error) {
                if !refreshing { state = .idle }
                return
            }
            Self.logger.error(
                "Listing Cloudflare D1 databases failed: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
            if refreshing {
                refreshError = error.localizedDescription
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private var holdsList: Bool {
        guard case .loaded = state else { return false }
        return true
    }

    nonisolated private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}
