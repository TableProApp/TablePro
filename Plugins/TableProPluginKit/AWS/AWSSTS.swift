import Foundation

public enum AWSSTS {
    public static func assumeRole(
        roleArn: String,
        roleSessionName: String,
        externalId: String?,
        durationSeconds: Int?,
        region: String,
        baseCredentials: AWSCredentials,
        session: URLSession,
        now: Date = Date()
    ) async throws -> AWSCredentials {
        let service = "sts"
        let host = "sts.\(region).amazonaws.com"

        var params: [(String, String)] = [
            ("Action", "AssumeRole"),
            ("Version", "2011-06-15"),
            ("RoleArn", roleArn),
            ("RoleSessionName", roleSessionName)
        ]
        if let durationSeconds {
            params.append(("DurationSeconds", String(durationSeconds)))
        }
        if let externalId, !externalId.isEmpty {
            params.append(("ExternalId", externalId))
        }

        let body = params
            .map { "\(AWSSigV4.uriEncode($0.0))=\(AWSSigV4.uriEncode($0.1))" }
            .joined(separator: "&")
        let bodyData = Data(body.utf8)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: now)
        formatter.dateFormat = "yyyyMMdd"
        let dateStamp = formatter.string(from: now)

        let contentType = "application/x-www-form-urlencoded; charset=utf-8"
        let payloadHash = AWSSigV4.sha256Hex(bodyData)

        var canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\nx-amz-date:\(amzDate)\n"
        var signedHeaders = "content-type;host;x-amz-date"
        if let sessionToken = baseCredentials.sessionToken, !sessionToken.isEmpty {
            canonicalHeaders += "x-amz-security-token:\(sessionToken)\n"
            signedHeaders = "content-type;host;x-amz-date;x-amz-security-token"
        }

        let canonicalRequest = [
            "POST", "/", "", canonicalHeaders, signedHeaders, payloadHash
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            AWSSigV4.sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let signingKey = AWSSigV4.deriveSigningKey(
            secretKey: baseCredentials.secretAccessKey,
            dateStamp: dateStamp,
            region: region,
            service: service
        )
        let signature = AWSSigV4.hmacHex(key: signingKey, data: Data(stringToSign.utf8))
        let authorization = "AWS4-HMAC-SHA256 "
            + "Credential=\(baseCredentials.accessKeyId)/\(credentialScope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"

        guard let url = URL(string: "https://\(host)/") else {
            throw AWSAuthError.assumeRoleFailed(role: roleArn, message: "Invalid STS endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let sessionToken = baseCredentials.sessionToken, !sessionToken.isEmpty {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AWSAuthError.assumeRoleFailed(role: roleArn, message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AWSAuthError.assumeRoleFailed(role: roleArn, message: "Unexpected STS response")
        }
        guard http.statusCode == 200 else {
            throw AWSAuthError.assumeRoleFailed(role: roleArn, message: stsErrorMessage(data) ?? "HTTP \(http.statusCode)")
        }

        return try parseAssumeRoleResponse(data, roleArn: roleArn)
    }

    public static func parseAssumeRoleResponse(_ data: Data, roleArn: String) throws -> AWSCredentials {
        let parser = CredentialsXMLParser()
        guard parser.parse(data),
              let accessKeyId = parser.accessKeyId,
              let secretAccessKey = parser.secretAccessKey,
              let sessionToken = parser.sessionToken
        else {
            throw AWSAuthError.assumeRoleFailed(role: roleArn, message: "Could not read credentials from the STS response")
        }
        let expiration = parser.expiration.flatMap(AWSCredentialResolver.parseISO8601)
        return AWSCredentials(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken,
            expiration: expiration
        )
    }

    private static func stsErrorMessage(_ data: Data) -> String? {
        let parser = ErrorXMLParser()
        guard parser.parse(data) else { return nil }
        switch (parser.code, parser.message) {
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
}

private final class CredentialsXMLParser: NSObject, XMLParserDelegate {
    var accessKeyId: String?
    var secretAccessKey: String?
    var sessionToken: String?
    var expiration: String?

    private var element = ""
    private var buffer = ""

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        element = elementName
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "AccessKeyId": accessKeyId = value
        case "SecretAccessKey": secretAccessKey = value
        case "SessionToken": sessionToken = value
        case "Expiration": expiration = value
        default: break
        }
        buffer = ""
    }
}

private final class ErrorXMLParser: NSObject, XMLParserDelegate {
    var code: String?
    var message: String?

    private var buffer = ""

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Code": code = value
        case "Message": message = value
        default: break
        }
        buffer = ""
    }
}
