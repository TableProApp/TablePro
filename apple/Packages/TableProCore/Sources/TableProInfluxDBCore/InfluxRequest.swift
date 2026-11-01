import Foundation

public struct InfluxRequest: Sendable, Equatable {
    public let method: String
    public let path: String
    public let queryItems: [URLQueryItem]
    public let headers: [String: String]
    public let body: Data?

    public init(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.path = path
        self.queryItems = queryItems
        self.headers = headers
        self.body = body
    }

    public func url(base: URL) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        // `+` is legal in a query, but every InfluxDB line reads it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}

public enum InfluxCredentials: Sendable, Equatable {
    case none
    case token(String)

    public init(token: String?) {
        let token = (token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self = token.isEmpty ? .none : .token(token)
    }

    /// 2.x reads `Token`, 3.x reads `Bearer`; both accept the other's word today, but the
    /// documented one is what a proxy in front of them is most likely to pass through.
    func authorization(for generation: InfluxGeneration?) -> String? {
        switch self {
        case .none:
            return nil
        case .token(let token):
            return generation == .v3 ? "Bearer \(token)" : "Token \(token)"
        }
    }
}

public enum InfluxRequests {
    /// 3.x with auth on refuses an anonymous `/ping`; before the version is known the token goes
    /// out with the `Token` word, which every line accepts.
    public static func ping(credentials: InfluxCredentials) -> InfluxRequest {
        InfluxRequest(method: "GET", path: "/ping", headers: authHeaders(credentials, generation: nil))
    }

    public static func listDatabases(
        generation: InfluxGeneration,
        organization: String,
        credentials: InfluxCredentials,
        offset: Int = 0
    ) -> InfluxRequest {
        let headers = authHeaders(credentials, generation: generation)
        switch generation {
        case .v3:
            return InfluxRequest(
                method: "GET",
                path: "/api/v3/configure/database",
                queryItems: [URLQueryItem(name: "format", value: "json")],
                headers: headers
            )
        case .v2:
            return InfluxRequest(
                method: "GET",
                path: "/api/v2/buckets",
                queryItems: [
                    URLQueryItem(name: "org", value: organization),
                    URLQueryItem(name: "limit", value: String(bucketPageSize)),
                    URLQueryItem(name: "offset", value: String(offset)),
                ],
                headers: headers
            )
        case .v1:
            return query("SHOW DATABASES", language: .influxQL, database: "", organization: organization,
                         generation: generation, credentials: credentials)
        }
    }

    public static let bucketPageSize = 100

    public static func listDBRPs(organization: String, credentials: InfluxCredentials) -> InfluxRequest {
        InfluxRequest(
            method: "GET",
            path: "/api/v2/dbrps",
            queryItems: [URLQueryItem(name: "org", value: organization)],
            headers: authHeaders(credentials, generation: .v2)
        )
    }

    public static func listOrganizations(credentials: InfluxCredentials) -> InfluxRequest {
        InfluxRequest(method: "GET", path: "/api/v2/orgs", headers: authHeaders(credentials, generation: .v2))
    }

    public static func query(
        _ statement: String,
        language: InfluxQueryLanguage,
        database: String,
        organization: String,
        generation: InfluxGeneration,
        credentials: InfluxCredentials
    ) -> InfluxRequest {
        var headers = authHeaders(credentials, generation: generation)
        switch (generation, language) {
        case (.v3, .sql), (.v3, .influxQL), (.v3, .flux):
            headers["Content-Type"] = "application/json"
            headers["Accept"] = "text/csv"
            let payload: [String: String] = ["db": database, "q": statement, "format": "csv"]
            return InfluxRequest(
                method: "POST",
                path: language == .sql ? "/api/v3/query_sql" : "/api/v3/query_influxql",
                headers: headers,
                body: try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            )
        case (_, .flux):
            headers["Content-Type"] = "application/json"
            headers["Accept"] = "application/csv"
            let payload: [String: Any] = [
                "query": statement,
                "type": "flux",
                "dialect": ["annotations": ["datatype"], "header": true],
            ]
            return InfluxRequest(
                method: "POST",
                path: "/api/v2/query",
                queryItems: [URLQueryItem(name: "org", value: organization)],
                headers: headers,
                body: try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            )
        case (_, .sql), (_, .influxQL):
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            headers["Accept"] = "application/json"
            var form = URLComponents()
            form.queryItems = [URLQueryItem(name: "q", value: statement)]
            if !database.isEmpty {
                form.queryItems?.append(URLQueryItem(name: "db", value: database))
            }
            let body = (form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
            return InfluxRequest(method: "POST", path: "/query", headers: headers, body: Data(body.utf8))
        }
    }

    static func authHeaders(_ credentials: InfluxCredentials, generation: InfluxGeneration?) -> [String: String] {
        guard let value = credentials.authorization(for: generation) else { return [:] }
        return ["Authorization": value]
    }
}

public enum InfluxCatalogDecoder {
    public static let systemDatabaseNames = ["_internal", "_monitoring", "_tasks"]

    /// `/api/v3/configure/database?format=json`: `[{"iox::database": "metrics"}]`.
    public static func v3Databases(_ data: Data) throws -> [String] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw InfluxError.malformedResponse(String(bytes: data.prefix(200), encoding: .utf8) ?? "")
        }
        return rows.compactMap { $0["iox::database"] as? String }
    }

    /// `/api/v2/orgs`: `{"orgs": [{"name": "tp"}, ...]}`.
    public static func v2Organizations(_ data: Data) throws -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let orgs = root["orgs"] as? [[String: Any]]
        else {
            throw InfluxError.malformedResponse(String(bytes: data.prefix(200), encoding: .utf8) ?? "")
        }
        return orgs.compactMap { $0["name"] as? String }
    }

    /// `/api/v2/buckets`: `{"buckets": [{"id": "1ef8...", "name": "metrics"}, ...]}`, as id and name.
    public static func v2Buckets(_ data: Data) throws -> [(id: String, name: String)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = root["buckets"] as? [[String: Any]]
        else {
            throw InfluxError.malformedResponse(String(bytes: data.prefix(200), encoding: .utf8) ?? "")
        }
        return buckets.compactMap { bucket in
            guard let name = bucket["name"] as? String else { return nil }
            return (bucket["id"] as? String ?? "", name)
        }
    }

    /// `/api/v2/dbrps`: the InfluxQL database name each bucket answers to, keyed by bucket id.
    /// InfluxQL resolves `db` through these mappings, not through bucket names. A mapping someone
    /// made wins over the virtual one 2.x makes per bucket, and a default one over the rest.
    public static func v2InfluxQLDatabases(_ data: Data) throws -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mappings = root["content"] as? [[String: Any]]
        else {
            throw InfluxError.malformedResponse(String(bytes: data.prefix(200), encoding: .utf8) ?? "")
        }
        func rank(_ mapping: [String: Any]) -> Int {
            (mapping["default"] as? Bool == true ? 2 : 0) + (mapping["virtual"] as? Bool == true ? 0 : 1)
        }
        var best: [String: [String: Any]] = [:]
        for mapping in mappings {
            guard let bucket = mapping["bucketID"] as? String, mapping["database"] is String else { continue }
            if let current = best[bucket], rank(current) >= rank(mapping) { continue }
            best[bucket] = mapping
        }
        return best.compactMapValues { $0["database"] as? String }
    }
}
