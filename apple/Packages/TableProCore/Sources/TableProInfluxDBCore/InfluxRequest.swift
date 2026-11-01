import Foundation

public struct InfluxRequest: Sendable, Equatable {
    public let method: String
    public let path: String
    public let query: [InfluxQueryItem]
    public let headers: [String: String]
    public let body: Data?

    public init(
        method: String,
        path: String,
        query: [InfluxQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    public func url(base: URL) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + path
        components.percentEncodedQuery = query.isEmpty ? nil : InfluxFormEncoding.encode(query)
        return components.url
    }
}

public struct InfluxQueryItem: Sendable, Equatable {
    public let name: String
    public let value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

// Go's `url.ParseQuery`, which every InfluxDB line reads forms with, drops a pair holding a raw `;` and reads `+` as a
// space, and `URLComponents` leaves both as they are. Only RFC 3986's unreserved characters go out unencoded.
public enum InfluxFormEncoding {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    public static func encode(_ items: [InfluxQueryItem]) -> String {
        items.map { escape($0.name) + "=" + escape($0.value) }.joined(separator: "&")
    }

    static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

public enum InfluxCredentials: Sendable, Equatable {
    case none
    case token(String)

    public init(token: String?) {
        let token = (token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self = token.isEmpty ? .none : .token(token)
    }

    // 2.x documents `Token`, 3.x documents `Bearer`; each accepts both, but a proxy in front passes the documented one.
    func authorization(for generation: InfluxGeneration?) -> String? {
        switch self {
        case .none: return nil
        case .token(let token): return generation == .v3 ? "Bearer \(token)" : "Token \(token)"
        }
    }
}

public enum InfluxRequests {
    public static let bucketPageSize = 100

    // 3.x with auth on refuses an anonymous `/ping`. Before the version is known the token goes out as `Token`.
    public static func ping(credentials: InfluxCredentials, generation: InfluxGeneration? = nil) -> InfluxRequest {
        InfluxRequest(method: "GET", path: "/ping", headers: authHeaders(credentials, generation: generation))
    }

    // 2.x's `/ping` never checks a token; this is its cheapest request that does, and it proves the organization too.
    public static func v2TokenCheck(organization: String, credentials: InfluxCredentials) -> InfluxRequest {
        InfluxRequest(
            method: "GET",
            path: "/api/v2/buckets",
            query: [InfluxQueryItem("org", organization), InfluxQueryItem("limit", "1")],
            headers: authHeaders(credentials, generation: .v2)
        )
    }

    public static func v3Databases(credentials: InfluxCredentials) -> InfluxRequest {
        InfluxRequest(
            method: "GET",
            path: "/api/v3/configure/database",
            query: [InfluxQueryItem("format", "json")],
            headers: authHeaders(credentials, generation: .v3)
        )
    }

    public static func v2Buckets(organization: String, credentials: InfluxCredentials, offset: Int) -> InfluxRequest {
        InfluxRequest(
            method: "GET",
            path: "/api/v2/buckets",
            query: [
                InfluxQueryItem("org", organization),
                InfluxQueryItem("limit", String(bucketPageSize)),
                InfluxQueryItem("offset", String(offset)),
            ],
            headers: authHeaders(credentials, generation: .v2)
        )
    }

    public static func v2Bucket(named name: String, organization: String, credentials: InfluxCredentials) -> InfluxRequest {
        InfluxRequest(
            method: "GET",
            path: "/api/v2/buckets",
            query: [InfluxQueryItem("org", organization), InfluxQueryItem("name", name)],
            headers: authHeaders(credentials, generation: .v2)
        )
    }

    public static func v2DBRPs(bucketID: String, organization: String, credentials: InfluxCredentials) -> InfluxRequest {
        InfluxRequest(
            method: "GET",
            path: "/api/v2/dbrps",
            query: [InfluxQueryItem("org", organization), InfluxQueryItem("bucketID", bucketID)],
            headers: authHeaders(credentials, generation: .v2)
        )
    }

    public static func v2Organizations(credentials: InfluxCredentials) -> InfluxRequest {
        InfluxRequest(method: "GET", path: "/api/v2/orgs", headers: authHeaders(credentials, generation: .v2))
    }

    public static func query(
        _ statement: InfluxStatement,
        database: String,
        retentionPolicy: String? = nil,
        organization: String,
        generation: InfluxGeneration,
        credentials: InfluxCredentials
    ) throws -> InfluxRequest {
        var headers = authHeaders(credentials, generation: generation)
        switch (generation, statement.language) {
        case (.v3, .sql), (.v3, .influxQL):
            headers["Content-Type"] = "application/json"
            headers["Accept"] = "text/csv"
            var payload = ["q": statement.text, "format": "csv"]
            if !database.isEmpty { payload["db"] = database }
            return InfluxRequest(
                method: "POST",
                path: statement.language == .sql ? "/api/v3/query_sql" : "/api/v3/query_influxql",
                headers: headers,
                body: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            )
        case (.v2, .flux):
            headers["Content-Type"] = "application/json"
            headers["Accept"] = "application/csv"
            let payload: [String: Any] = [
                "query": statement.text,
                "type": "flux",
                "dialect": ["annotations": ["datatype"], "header": true],
            ]
            return InfluxRequest(
                method: "POST",
                path: "/api/v2/query",
                query: [InfluxQueryItem("org", organization)],
                headers: headers,
                body: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            )
        case (.v2, .influxQL):
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            headers["Accept"] = "application/json"
            var form = [InfluxQueryItem("q", statement.text)]
            if !database.isEmpty { form.append(InfluxQueryItem("db", database)) }
            if let retentionPolicy, !retentionPolicy.isEmpty { form.append(InfluxQueryItem("rp", retentionPolicy)) }
            return InfluxRequest(
                method: "POST",
                path: "/query",
                headers: headers,
                body: Data(InfluxFormEncoding.encode(form).utf8)
            )
        case (.v3, .flux), (.v2, .sql):
            throw InfluxError.unsupportedLanguage(statement.language, generation: generation)
        }
    }

    static func authHeaders(_ credentials: InfluxCredentials, generation: InfluxGeneration?) -> [String: String] {
        guard let value = credentials.authorization(for: generation) else { return [:] }
        return ["Authorization": value]
    }
}

public struct InfluxQLTarget: Sendable, Equatable {
    public let database: String
    public let retentionPolicy: String?
    public let isDefault: Bool

    public init(database: String, retentionPolicy: String?, isDefault: Bool = true) {
        self.database = database
        self.retentionPolicy = retentionPolicy
        self.isDefault = isDefault
    }
}

public enum InfluxCatalogDecoder {
    public static let systemDatabaseNames = ["_internal", "_monitoring", "_tasks"]

    // `[{"iox::database": "metrics"}]`
    public static func v3Databases(_ data: Data) throws -> [String] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw InfluxError.malformedResponse(InfluxResponseDecoder.preview(of: data))
        }
        return rows.compactMap { $0["iox::database"] as? String }
    }

    public static func v2Organizations(_ data: Data) throws -> [String] {
        try objects(in: data, key: "orgs").compactMap { $0["name"] as? String }
    }

    public static func v2BucketNames(_ data: Data) throws -> [String] {
        try objects(in: data, key: "buckets").compactMap { $0["name"] as? String }
    }

    public static func v2BucketID(_ data: Data) throws -> String? {
        try objects(in: data, key: "buckets").first?["id"] as? String
    }

    // InfluxQL names a bucket by its DBRP mapping, not its name: `telegraf/weekly` is `db=telegraf&rp=weekly`, and a
    // mapping someone made may name another database. A default mapping wins, then a made one over the virtual one.
    public static func v2InfluxQLTarget(_ data: Data) throws -> InfluxQLTarget? {
        func rank(_ mapping: [String: Any]) -> Int {
            (mapping["default"] as? Bool == true ? 2 : 0) + (mapping["virtual"] as? Bool == true ? 0 : 1)
        }
        guard let best = try objects(in: data, key: "content")
            .filter({ $0["database"] is String })
            .max(by: { rank($0) < rank($1) }),
            let database = best["database"] as? String
        else { return nil }
        return InfluxQLTarget(
            database: database,
            retentionPolicy: best["retention_policy"] as? String,
            isDefault: best["default"] as? Bool ?? false
        )
    }

    private static func objects(in data: Data, key: String) throws -> [[String: Any]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let objects = root[key] as? [[String: Any]]
        else {
            throw InfluxError.malformedResponse(InfluxResponseDecoder.preview(of: data))
        }
        return objects
    }
}
