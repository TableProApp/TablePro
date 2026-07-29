import Foundation

public enum KeyspacesSigV4 {
    public static let initialResponse = "SigV4\u{0}\u{0}"
    public static let nonceKey = "nonce="
    public static let nonceLength = 32
    private static let service = "cassandra"
    private static let expirySeconds = 900

    public static func nonce(fromChallenge challenge: Data) -> Data? {
        let key = Data(nonceKey.utf8)
        guard let range = challenge.range(of: key) else { return nil }
        let start = range.upperBound
        let end = start + nonceLength
        guard end <= challenge.endIndex else { return nil }
        return challenge.subdata(in: start..<end)
    }

    public static func authResponse(
        nonce: Data,
        credentials: AWSCredentials,
        region: String,
        now: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: now)
        formatter.dateFormat = "yyyyMMdd"
        let dateStamp = formatter.string(from: now)

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let credential = "\(credentials.accessKeyId)/\(scope)"

        let params: [(String, String)] = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", credential),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", String(expirySeconds))
        ]
        let query = params
            .map { (AWSSigV4.uriEncode($0.0), AWSSigV4.uriEncode($0.1)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")

        let payloadHash = AWSSigV4.sha256Hex(nonce)
        let canonicalRequest = "PUT\n/authenticate\n\(query)\nhost:\(service)\n\nhost\n\(payloadHash)"

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            AWSSigV4.sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let signingKey = AWSSigV4.deriveSigningKey(
            secretKey: credentials.secretAccessKey,
            dateStamp: dateStamp,
            region: region,
            service: service
        )
        let signature = AWSSigV4.hmacHex(key: signingKey, data: Data(stringToSign.utf8))

        var response = "signature=\(signature),access_key=\(credentials.accessKeyId),amzdate=\(amzDate)"
        if let sessionToken = credentials.sessionToken, !sessionToken.isEmpty {
            response += ",session_token=\(sessionToken)"
        }
        return response
    }
}
