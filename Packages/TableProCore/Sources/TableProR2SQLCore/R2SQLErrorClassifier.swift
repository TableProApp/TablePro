import Foundation

public enum R2SQLErrorClassifier {
    public static let missingTokenCode = 80_007
    public static let invalidTokenCode = 80_011
    public static let invalidAccountCode = 80_016

    private static let authenticationCodes: Set<Int> = [missingTokenCode, invalidTokenCode]

    public static func decode(_ response: R2SQLHTTPResponse) -> Result<R2SQLResult, R2SQLError> {
        guard let envelope = try? JSONDecoder().decode(R2SQLEnvelope.self, from: response.body) else {
            return .failure(.malformedResponse(
                status: response.statusCode,
                body: String(data: response.body, encoding: .utf8) ?? ""
            ))
        }

        guard envelope.success else {
            return .failure(classify(errors: envelope.errors, statusCode: response.statusCode))
        }

        guard let result = envelope.result else {
            return .success(R2SQLResult(schema: [], rows: []))
        }
        return .success(result)
    }

    public static func classify(errors: [R2SQLAPIError], statusCode: Int) -> R2SQLError {
        guard let first = errors.first else {
            return authenticationStatus(statusCode) ?? .malformedResponse(status: statusCode, body: "")
        }

        if authenticationCodes.contains(first.code) {
            return .authentication(authenticationGuidance(first.message))
        }
        if first.code == invalidAccountCode {
            return .authentication("\(first.message). Check the Account ID on this connection.")
        }
        if let status = authenticationStatus(statusCode) {
            return status
        }
        return errors.count == 1 ? .query(first) : .api(errors)
    }

    private static func authenticationStatus(_ statusCode: Int) -> R2SQLError? {
        switch statusCode {
        case 401:
            return .authentication(authenticationGuidance("Unauthenticated."))
        case 403:
            return .authentication(authenticationGuidance("Forbidden."))
        default:
            return nil
        }
    }

    private static func authenticationGuidance(_ message: String) -> String {
        """
        \(message) The API token needs the R2 SQL, R2 Data Catalog and R2 Storage permission groups \
        for this account.
        """
    }
}
