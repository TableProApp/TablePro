//
//  RDSAuthTokenGenerator.swift
//  TablePro
//
//  Builds an RDS IAM authentication token: a SigV4 presigned GET URL for the
//  rds-db connect action, with the scheme stripped. The token is used as the
//  database password and is valid for 15 minutes.
//

import Foundation

enum RDSAuthTokenGenerator {
    private static let service = "rds-db"
    private static let expirySeconds = 900

    static func generateToken(
        host: String,
        port: Int,
        region: String,
        username: String,
        credentials: AWSCredentials,
        now: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: now)
        formatter.dateFormat = "yyyyMMdd"
        let dateStamp = formatter.string(from: now)

        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let credential = "\(credentials.accessKeyId)/\(credentialScope)"

        var params: [(String, String)] = [
            ("Action", "connect"),
            ("DBUser", username),
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", credential),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", String(expirySeconds)),
            ("X-Amz-SignedHeaders", "host")
        ]
        if let sessionToken = credentials.sessionToken, !sessionToken.isEmpty {
            params.append(("X-Amz-Security-Token", sessionToken))
        }

        let canonicalQuery = params
            .map { (AWSSigV4.uriEncode($0.0), AWSSigV4.uriEncode($0.1)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")

        let canonicalHeaders = "host:\(host):\(port)\n"
        let signedHeaders = "host"
        let payloadHash = AWSSigV4.sha256Hex(Data())

        let canonicalRequest = [
            "GET",
            "/",
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            AWSSigV4.sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let signingKey = AWSSigV4.deriveSigningKey(
            secretKey: credentials.secretAccessKey,
            dateStamp: dateStamp,
            region: region,
            service: service
        )
        let signature = AWSSigV4.hmacHex(key: signingKey, data: Data(stringToSign.utf8))

        let url = "https://\(host):\(port)/?\(canonicalQuery)&X-Amz-Signature=\(signature)"
        return String(url.dropFirst("https://".count))
    }
}
