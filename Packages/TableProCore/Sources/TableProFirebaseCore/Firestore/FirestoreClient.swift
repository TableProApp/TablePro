import Foundation

/// The Firestore REST API (v1) for one project, over any database in it.
public final class FirestoreClient: @unchecked Sendable {
    public let projectId: String
    private let baseURL: URL
    private let requester: FirebaseRequester
    private let lock = NSLock()
    private var database: String

    public init(
        projectId: String,
        database: String,
        baseURL: URL,
        transport: any FirebaseTransport,
        credential: FirebaseCredential,
        timeout: @escaping @Sendable () -> TimeInterval
    ) {
        self.projectId = projectId
        self.database = database
        self.baseURL = baseURL
        self.requester = FirebaseRequester(transport: transport, credential: credential, timeout: timeout)
    }

    public var currentDatabase: String {
        lock.withLock { database }
    }

    public func switchDatabase(to name: String) {
        lock.withLock { database = name }
    }

    public var documentRoot: String {
        "projects/\(projectId)/databases/\(currentDatabase)/documents"
    }

    // MARK: - Catalog

    /// Native-mode databases only: a Datastore-mode database answers every Firestore call with an
    /// error, so offering it would only lead to one.
    public func listDatabases() async throws -> [String] {
        let response = try await requester.send(method: "GET", url: try url("projects/\(projectId)/databases"))
        try check(response, operation: String(localized: "list databases"))
        let databases = try response.json()["databases"]?.arrayValue ?? []
        return databases.compactMap { database -> String? in
            guard let name = database["name"]?.stringValue else { return nil }
            let type = database["type"]?.stringValue ?? "FIRESTORE_NATIVE"
            return type == "FIRESTORE_NATIVE" ? FirestorePath.lastSegment(name) : nil
        }.sorted()
    }

    /// `parent` is a document path, or empty for the root collections.
    public func listCollectionIds(parent: String, limit: Int = 1_000) async throws -> [String] {
        var ids: [String] = []
        var pageToken: String?
        repeat {
            var body: [String: FirebaseJSON] = ["pageSize": .int(Int64(min(limit, 300)))]
            if let pageToken { body["pageToken"] = .string(pageToken) }
            let response = try await requester.send(
                method: "POST",
                url: try url(documentName(parent) + ":listCollectionIds"),
                body: FirebaseJSON.object(body).data()
            )
            try check(response, operation: String(format: String(localized: "list the collections of %@"), parent.isEmpty ? "/" : parent))
            let json = try response.json()
            ids += (json["collectionIds"]?.arrayValue ?? []).compactMap(\.stringValue)
            pageToken = json["nextPageToken"]?.stringValue
        } while pageToken != nil && ids.count < limit
        return ids
    }

    // MARK: - Reads

    public func runQuery(parent: String, body: FirebaseJSON, operation: String) async throws -> [FirestoreDocument] {
        let response = try await requester.send(
            method: "POST",
            url: try url(documentName(parent) + ":runQuery"),
            body: body.data()
        )
        try check(response, operation: operation)
        let root = documentRoot
        return try (response.json().arrayValue ?? []).compactMap { item in
            guard let document = item["document"] else { return nil }
            return try FirestoreDocument(rest: document, documentRoot: root)
        }
    }

    public func count(parent: String, body: FirebaseJSON, operation: String) async throws -> Int? {
        let response = try await requester.send(
            method: "POST",
            url: try url(documentName(parent) + ":runAggregationQuery"),
            body: body.data()
        )
        try check(response, operation: operation)
        for item in try response.json().arrayValue ?? [] {
            if let total = item["result"]?["aggregateFields"]?["total"]?["integerValue"] {
                switch total {
                case .string(let text): return Int(text)
                case .int(let value): return Int(value)
                default: return nil
                }
            }
        }
        return nil
    }

    public func getDocument(_ path: String) async throws -> FirestoreDocument? {
        let response = try await requester.send(method: "GET", url: try url(documentName(path)))
        if response.statusCode == 404 { return nil }
        try check(response, operation: String(format: String(localized: "read %@"), path))
        return try FirestoreDocument(rest: response.json(), documentRoot: documentRoot)
    }

    // MARK: - Writes

    /// A nil `documentId` lets Firestore pick one.
    public func createDocument(
        collectionPath: String,
        documentId: String?,
        fields: [String: FirestoreValue]
    ) async throws -> FirestoreDocument {
        let split = FirestorePath.split(collectionPath: collectionPath)
        var query: [URLQueryItem] = []
        if let documentId, !documentId.isEmpty {
            query.append(URLQueryItem(name: "documentId", value: documentId))
        }
        let root = documentRoot
        let response = try await requester.send(
            method: "POST",
            url: try url(documentName(split.parent) + "/" + Self.encodedSegment(split.collectionId), query: query),
            body: FirebaseJSON.object(["fields": .object(fields.mapValues { $0.rest(documentRoot: root) })]).data()
        )
        try check(response, operation: String(format: String(localized: "create a document in %@"), collectionPath))
        return try FirestoreDocument(rest: response.json(), documentRoot: root)
    }

    /// With a `mask`, only the named fields change and a masked field missing from `fields` is
    /// removed. Without one the whole document is replaced. `updateTime` refuses the write when the
    /// document changed after that time was read.
    public func patchDocument(
        _ path: String,
        fields: [String: FirestoreValue],
        mask: [String]?,
        updateTime: String? = nil,
        mustExist: Bool = true
    ) async throws {
        var query = (mask ?? []).map { URLQueryItem(name: "updateMask.fieldPaths", value: FirestoreQueryBuilder.fieldPath($0)) }
        if let updateTime {
            query.append(URLQueryItem(name: "currentDocument.updateTime", value: updateTime))
        } else if mustExist {
            query.append(URLQueryItem(name: "currentDocument.exists", value: "true"))
        }
        let root = documentRoot
        let response = try await requester.send(
            method: "PATCH",
            url: try url(documentName(path), query: query),
            body: FirebaseJSON.object(["fields": .object(fields.mapValues { $0.rest(documentRoot: root) })]).data()
        )
        try check(response, operation: String(format: String(localized: "write %@"), path))
    }

    public func deleteDocument(_ path: String) async throws {
        let response = try await requester.send(method: "DELETE", url: try url(documentName(path)))
        try check(response, operation: String(format: String(localized: "delete %@"), path))
    }

    // MARK: - Console

    /// A request typed in the editor, against a path under the current database's documents.
    public func console(method: String, path: String, query: [URLQueryItem], body: FirebaseJSON?) async throws -> FirebaseJSON {
        let response = try await requester.send(
            method: method,
            url: try url(documentName(path), query: query),
            body: body?.data()
        )
        try check(response, operation: "\(method) \(path)")
        return try response.json()
    }

    public func ping() async throws {
        _ = try await listCollectionIds(parent: "", limit: 1)
    }

    // MARK: - URLs

    func documentName(_ path: String) -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map { Self.encodedSegment(String($0)) }
        let root = "projects/\(Self.encodedSegment(projectId))/databases/\(Self.encodedSegment(currentDatabase))/documents"
        return segments.isEmpty ? root : root + "/" + segments.joined(separator: "/")
    }

    func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: baseURL.absoluteString + path) else {
            throw FirebaseError.configuration(String(format: String(localized: "\"%@\" is not a valid path."), path))
        }
        if !query.isEmpty {
            components.percentEncodedQuery = query.map { item in
                "\(Self.encodedQuery(item.name))=\(Self.encodedQuery(item.value ?? ""))"
            }.joined(separator: "&")
        }
        guard let url = components.url else {
            throw FirebaseError.configuration(String(format: String(localized: "\"%@\" is not a valid path."), path))
        }
        return url
    }

    static func encodedSegment(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    static func encodedQuery(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private func check(_ response: FirebaseHTTPResponse, operation: String) throws {
        guard !response.isSuccess else { return }
        throw FirebaseError.from(status: response.statusCode, body: response.body, operation: operation)
    }
}
