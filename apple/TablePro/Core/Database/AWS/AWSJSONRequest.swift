//
//  AWSJSONRequest.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// A SigV4-signed call to an AWS service that speaks the JSON 1.1 protocol.
struct AWSJSONRequest: Sendable, Equatable {
    static let contentType = "application/x-amz-json-1.1"

    let service: String
    let region: String
    let host: String
    let target: String
    let body: Data

    init(service: String, region: String, target: String, body: Data) {
        let canonicalRegion = AWSPartition.canonicalRegion(region)
        self.service = service
        self.region = canonicalRegion
        host = AWSPartition.host(service: service, region: canonicalRegion)
        self.target = target
        self.body = body
    }

    func signedURLRequest(credentials: AWSCredentials, now: Date = Date()) throws -> URLRequest {
        guard let url = URL(string: "https://\(host)/") else {
            throw AWSAuthError.missingConfiguration(
                String(
                    format: String(localized: "Could not build the %1$@ endpoint for the AWS region \"%2$@\"."),
                    service, region
                )
            )
        }

        let stamps = Self.timestamps(for: now)
        var headers = [
            "content-type": Self.contentType,
            "host": host,
            "x-amz-date": stamps.amzDate,
            "x-amz-target": target
        ]
        if let sessionToken = credentials.sessionToken, !sessionToken.isEmpty {
            headers["x-amz-security-token"] = sessionToken
        }

        let signedHeaderNames = headers.keys.sorted()
        let canonicalHeaders = signedHeaderNames.map { "\($0):\(headers[$0] ?? "")\n" }.joined()
        let signedHeaders = signedHeaderNames.joined(separator: ";")
        let canonicalRequest = [
            "POST",
            "/",
            "",
            canonicalHeaders,
            signedHeaders,
            AWSSigV4.sha256Hex(body)
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
        request.httpBody = body
        for name in signedHeaderNames {
            request.setValue(headers[name], forHTTPHeaderField: name)
        }
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(credentialScope), "
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
}
