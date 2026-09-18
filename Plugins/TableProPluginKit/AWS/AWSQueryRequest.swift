import Foundation

public struct AWSQueryRequest: Sendable, Equatable {
    public static let contentType = "application/x-www-form-urlencoded; charset=utf-8"

    public let service: String
    public let region: String
    public let host: String
    public let parameters: [String: String]

    public init(service: String, region: String, host: String? = nil, parameters: [String: String]) {
        let canonicalRegion = AWSPartition.canonicalRegion(region)
        self.service = service
        self.region = canonicalRegion
        self.host = host ?? AWSPartition.host(service: service, region: canonicalRegion)
        self.parameters = parameters
    }

    public var body: Data {
        let encoded = parameters
            .sorted { $0.key < $1.key }
            .map { "\(AWSSigV4.uriEncode($0.key))=\(AWSSigV4.uriEncode($0.value))" }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    public func signedURLRequest(credentials: AWSCredentials, now: Date = Date()) throws -> URLRequest {
        guard let url = URL(string: "https://\(host)/") else {
            throw AWSAuthError.missingConfiguration(
                String(
                    format: String(localized: "Could not build the %1$@ endpoint for the AWS region \"%2$@\"."),
                    service, region
                )
            )
        }

        let payload = body
        let stamps = Self.timestamps(for: now)
        var headers = [
            "content-type": Self.contentType,
            "host": host,
            "x-amz-date": stamps.amzDate
        ]
        if let sessionToken = credentials.sessionToken, !sessionToken.isEmpty {
            headers["x-amz-security-token"] = sessionToken
        }

        let signedHeaderNames = headers.keys.sorted()
        let canonicalHeaders = signedHeaderNames
            .map { "\($0):\(Self.canonicalValue(headers[$0] ?? ""))\n" }
            .joined()
        let signedHeaders = signedHeaderNames.joined(separator: ";")
        let canonicalRequest = [
            "POST",
            "/",
            "",
            canonicalHeaders,
            signedHeaders,
            AWSSigV4.sha256Hex(payload)
        ].joined(separator: "\n")

        let credentialScope = "\(stamps.dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            stamps.amzDate,
            credentialScope,
            AWSSigV4.sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let signingKey = AWSSigV4.deriveSigningKey(
            secretKey: credentials.secretAccessKey,
            dateStamp: stamps.dateStamp,
            region: region,
            service: service
        )
        let signature = AWSSigV4.hmacHex(key: signingKey, data: Data(stringToSign.utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        for name in signedHeaderNames {
            request.setValue(headers[name], forHTTPHeaderField: name)
        }
        request.setValue(
            "AWS4-HMAC-SHA256 "
                + "Credential=\(credentials.accessKeyId)/\(credentialScope), "
                + "SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    private static func timestamps(for now: Date) -> (amzDate: String, dateStamp: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: now)
        formatter.dateFormat = "yyyyMMdd"
        return (amzDate, formatter.string(from: now))
    }

    private static func canonicalValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}

public struct AWSQueryErrorResponse: Sendable, Equatable {
    public let code: String?
    public let message: String?

    public init(code: String?, message: String?) {
        self.code = code
        self.message = message
    }

    public var summary: String? {
        switch (code, message) {
        case let (code?, message?):
            return "\(code): \(message)"
        case let (code?, nil):
            return code
        case let (nil, message?):
            return message
        default:
            return nil
        }
    }

    public static func parse(_ data: Data) -> AWSQueryErrorResponse? {
        let parser = AWSQueryErrorXMLParser()
        guard parser.parse(data), parser.code != nil || parser.message != nil else { return nil }
        return AWSQueryErrorResponse(code: parser.code, message: parser.message)
    }
}

private final class AWSQueryErrorXMLParser: NSObject, XMLParserDelegate {
    var code: String?
    var message: String?

    private var buffer = ""

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Code":
            code = value
        case "Message":
            message = value
        default:
            break
        }
        buffer = ""
    }
}
