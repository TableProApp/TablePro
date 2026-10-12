import Foundation
import TableProPluginKit

/// Signature Version 4 for DynamoDB's JSON protocol.
enum DynamoDBSigner {
    static let service = "dynamodb"

    struct Timestamps: Equatable {
        let amzDate: String
        let dateStamp: String
    }

    static func timestamps(for date: Date) -> Timestamps {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: date)
        return Timestamps(amzDate: amzDate, dateStamp: String(amzDate.prefix(8)))
    }

    /// The `Host` value: the port only when it is not the scheme's default, as every AWS SDK sends it.
    static func hostHeader(for url: URL) -> String {
        let bare = url.host ?? ""
        let host = bare.contains(":") ? "[\(bare)]" : bare
        guard let port = url.port else { return host }
        let scheme = url.scheme?.lowercased()
        let isDefault = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return isDefault ? host : "\(host):\(port)"
    }

    /// The canonical URI keeps the path exactly as it is sent, percent-encoding and trailing slash
    /// included. `URL.path` decodes `%20` and drops the slash, which signs a path the server never
    /// sees.
    static func canonicalURI(for url: URL) -> String {
        let path = url.path(percentEncoded: true)
        return path.isEmpty ? "/" : path
    }

    static func sign(
        _ request: inout URLRequest,
        body: Data,
        credentials: AWSCredentials,
        region: String,
        date: Date
    ) {
        guard let url = request.url else { return }
        let stamps = timestamps(for: date)
        var headers: [String: String] = [
            "content-type": request.value(forHTTPHeaderField: "Content-Type") ?? "",
            "host": hostHeader(for: url),
            "x-amz-date": stamps.amzDate,
            "x-amz-target": request.value(forHTTPHeaderField: "X-Amz-Target") ?? ""
        ]
        if let token = credentials.sessionToken, !token.isEmpty {
            headers["x-amz-security-token"] = token
        }
        let signedNames = headers.keys.sorted()
        let canonicalHeaders = signedNames.map { "\($0):\(canonicalValue(headers[$0] ?? ""))\n" }.joined()
        let signedHeaders = signedNames.joined(separator: ";")
        let canonicalRequest = [
            request.httpMethod ?? "POST",
            canonicalURI(for: url),
            canonicalQuery(for: url),
            canonicalHeaders,
            signedHeaders,
            AWSSigV4.sha256Hex(body)
        ].joined(separator: "\n")

        let scope = "\(stamps.dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            stamps.amzDate,
            scope,
            AWSSigV4.sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")
        let key = AWSSigV4.deriveSigningKey(
            secretKey: credentials.secretAccessKey, dateStamp: stamps.dateStamp, region: region, service: service
        )
        let signature = AWSSigV4.hmacHex(key: key, data: Data(stringToSign.utf8))

        request.setValue(headers["host"], forHTTPHeaderField: "Host")
        request.setValue(stamps.amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let token = headers["x-amz-security-token"] {
            request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token")
        }
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), "
                + "SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    /// The query string as SigV4 signs it: every name and value encoded, sorted by name then value.
    static func canonicalQuery(for url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, !items.isEmpty else {
            return ""
        }
        let pairs: [(name: String, value: String)] = items.map { item in
            (AWSSigV4.uriEncode(item.name), AWSSigV4.uriEncode(item.value ?? ""))
        }
        let sorted = pairs.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
        }
        return sorted.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    private static func canonicalValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
