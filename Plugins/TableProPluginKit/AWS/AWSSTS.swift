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
        var parameters: [String: String] = [
            "Action": "AssumeRole",
            "Version": "2011-06-15",
            "RoleArn": roleArn,
            "RoleSessionName": roleSessionName
        ]
        if let durationSeconds {
            parameters["DurationSeconds"] = String(durationSeconds)
        }
        if let externalId, !externalId.isEmpty {
            parameters["ExternalId"] = externalId
        }

        let query = AWSQueryRequest(service: "sts", region: region, parameters: parameters)
        let request = try query.signedURLRequest(credentials: baseCredentials, now: now)

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
        AWSQueryErrorResponse.parse(data)?.summary
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
