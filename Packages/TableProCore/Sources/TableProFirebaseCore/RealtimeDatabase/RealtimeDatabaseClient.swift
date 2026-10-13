import Foundation

public final class RealtimeDatabaseClient: @unchecked Sendable {
    private let requester: FirebaseRequester
    private let lock = NSLock()
    private var instanceURL: URL

    public init(
        instanceURL: URL,
        transport: any FirebaseTransport,
        credential: FirebaseCredential,
        timeout: @escaping @Sendable () -> TimeInterval
    ) {
        self.instanceURL = instanceURL
        self.requester = FirebaseRequester(transport: transport, credential: credential, timeout: timeout)
    }

    public var currentURL: URL {
        lock.withLock { instanceURL }
    }

    public func switchInstance(to url: URL) {
        lock.withLock { instanceURL = url }
    }

    public var instanceName: String {
        Self.instanceName(of: currentURL)
    }

    /// The host's first label, or the emulator's `ns`.
    public static func instanceName(of url: URL) -> String {
        if let namespace = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "ns" })?.value {
            return namespace
        }
        return url.host?.split(separator: ".").first.map(String.init) ?? url.absoluteString
    }

    // MARK: - Reads

    public func get(_ path: String, query: [URLQueryItem] = []) async throws -> FirebaseJSON {
        let response = try await requester.send(method: "GET", url: try url(path, query: query))
        try response.requireSuccess(String(format: String(localized: "read %@"), Self.display(path)))
        return try response.json()
    }

    public func getWithETag(_ path: String) async throws -> (value: FirebaseJSON, etag: String?) {
        let response = try await requester.send(
            method: "GET",
            url: try url(path),
            headers: ["X-Firebase-ETag": "true"]
        )
        try response.requireSuccess(String(format: String(localized: "read %@"), Self.display(path)))
        return (try response.json(), response.header("ETag"))
    }

    public func childKeys(_ path: String) async throws -> [String] {
        let json = try await get(path, query: [URLQueryItem(name: "shallow", value: "true")])
        guard case .object(let members) = json else { return [] }
        return members.keys.sorted(by: RealtimeDatabaseOrdering.keyPrecedes)
    }

    public func children(_ path: String, plan: RealtimeDatabaseReadPlan) async throws -> [(key: String, value: FirebaseJSON)] {
        let json = try await get(path, query: plan.queryItems)
        let children: [(key: String, value: FirebaseJSON)]
        switch json {
        case .object(let members):
            children = members.map { ($0.key, $0.value) }
        case .array(let values):
            children = values.enumerated().compactMap { index, value in
                value == .null ? nil : (String(index), value)
            }
        case .null:
            children = []
        default:
            children = [("", json)]
        }
        return plan.window(RealtimeDatabaseOrdering.sort(children, order: plan.order, ascending: plan.ascending))
    }

    // MARK: - Writes

    /// The server refuses `print=silent` on a conditional write. A refused one answers 412 with the
    /// node's current data as the body, which must not reach the error text.
    public func put(_ path: String, value: FirebaseJSON, ifMatch: String? = nil) async throws {
        var headers: [String: String] = [:]
        var query = [URLQueryItem(name: "print", value: "silent")]
        if let ifMatch {
            headers["if-match"] = ifMatch
            query = []
        }
        let response = try await requester.send(
            method: "PUT",
            url: try url(path, query: query),
            body: value.data(),
            headers: headers
        )
        if ifMatch != nil, response.statusCode == 412 {
            throw FirebaseError.precondition(String(localized: "The node changed after it was read."))
        }
        try response.requireSuccess(String(format: String(localized: "write %@"), Self.display(path)))
    }

    public func patch(_ path: String, values: [String: FirebaseJSON]) async throws {
        let response = try await requester.send(
            method: "PATCH",
            url: try url(path, query: [URLQueryItem(name: "print", value: "silent")]),
            body: FirebaseJSON.object(values).data()
        )
        try response.requireSuccess(String(format: String(localized: "write %@"), Self.display(path)))
    }

    public func push(_ path: String, value: FirebaseJSON) async throws -> String? {
        let response = try await requester.send(method: "POST", url: try url(path), body: value.data())
        try response.requireSuccess(String(format: String(localized: "write %@"), Self.display(path)))
        return try response.json()["name"]?.stringValue
    }

    public func delete(_ path: String) async throws {
        let response = try await requester.send(method: "DELETE", url: try url(path, query: [URLQueryItem(name: "print", value: "silent")]))
        try response.requireSuccess(String(format: String(localized: "delete %@"), Self.display(path)))
    }

    /// Reads at most one root child and sends none of it back. A shallow read lists every root key,
    /// and `shallow` cannot be combined with a limit.
    public func ping() async throws {
        let query = [
            URLQueryItem(name: "orderBy", value: RealtimeDatabaseReadPlan.orderParameter(.key)),
            URLQueryItem(name: "limitToFirst", value: "1"),
            URLQueryItem(name: "print", value: "silent")
        ]
        let response = try await requester.send(method: "GET", url: try url("", query: query))
        try response.requireSuccess(String(format: String(localized: "read %@"), "/"))
    }

    /// An instance outside us-central1 answers its `firebaseio.com` name with a 404 naming its real
    /// URL, adopted only when it is a Firebase host since the token goes wherever it points.
    public func locate() async throws {
        let shallow = [URLQueryItem(name: "shallow", value: "true")]
        let response = try await requester.send(method: "GET", url: try url("", query: shallow))
        if response.statusCode == 404, let corrected = Self.correctURL(in: response.body) {
            switchInstance(to: corrected)
            try await ping()
            return
        }
        try response.requireSuccess(String(format: String(localized: "read %@"), "/"))
    }

    static func correctURL(in body: Data) -> URL? {
        guard let text = (try? FirebaseJSON.parse(body))?["correctUrl"]?.stringValue else { return nil }
        return try? FirebaseConnectionSettings.parseDatabaseURL(text, emulator: false)
    }

    // MARK: - URLs

    func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        let base = currentURL
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw FirebaseError.configuration(String(localized: "The Database URL is not valid."))
        }
        let segments = RealtimeDatabasePath.normalized(path).split(separator: "/").map { segment in
            String(segment).addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) ?? String(segment)
        }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let joined = ([basePath].filter { !$0.isEmpty } + segments).joined(separator: "/")
        components.percentEncodedPath = "/" + joined + ".json"
        let namespace = components.queryItems?.filter { $0.name == "ns" } ?? []
        components.percentEncodedQuery = FirebaseRequester.queryString(namespace + query)
        guard let url = components.url else {
            throw FirebaseError.configuration(String(format: String(localized: "\"%@\" is not a valid path."), path))
        }
        return url
    }

    private static let segmentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return allowed
    }()

    static func display(_ path: String) -> String {
        "/" + RealtimeDatabasePath.normalized(path)
    }
}

public struct RealtimeDatabaseInstanceLister: Sendable {
    private let requester: FirebaseRequester

    public init(transport: any FirebaseTransport, credential: FirebaseCredential, timeout: @escaping @Sendable () -> TimeInterval) {
        self.requester = FirebaseRequester(transport: transport, credential: credential, timeout: timeout)
    }

    public func instances(projectId: String) async throws -> [URL] {
        guard let url = URL(string: "https://firebasedatabase.googleapis.com/v1beta/projects/\(projectId)/locations/-/instances?pageSize=100") else {
            return []
        }
        var response = try await requester.send(method: "GET", url: url)
        if response.statusCode == 403, Self.needsQuotaProject(response.body) {
            response = try await requester.send(method: "GET", url: url, headers: ["x-goog-user-project": projectId])
        }
        guard response.isSuccess else {
            throw FirebaseError.from(status: response.statusCode, body: response.body, operation: String(localized: "list database instances"))
        }
        let instances = try response.json()["instances"]?.arrayValue ?? []
        return instances.compactMap { instance -> URL? in
            guard instance["state"]?.stringValue != "DISABLED",
                  let text = instance["databaseUrl"]?.stringValue else { return nil }
            return URL(string: text.hasSuffix("/") ? text : text + "/")
        }.sorted { RealtimeDatabaseClient.instanceName(of: $0) < RealtimeDatabaseClient.instanceName(of: $1) }
    }

    /// The browsed project is billed only when the API asks for a quota project, so a credential
    /// that may not bill it is never refused for it.
    static func needsQuotaProject(_ body: Data) -> Bool {
        (FirebaseError.apiMessage(from: body) ?? "").localizedCaseInsensitiveContains("quota project")
    }
}
