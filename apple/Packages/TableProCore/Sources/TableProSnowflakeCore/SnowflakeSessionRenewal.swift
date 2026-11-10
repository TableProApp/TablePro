import Foundation

// A session token expires while a statement is still running. The request the server refused is
// sent again as it was, with the renewed token: a submit keeps its request id, which the server
// deduplicates on, and a poll keeps its result URL. The statement itself is never submitted anew.
public enum SnowflakeSessionRenewal {
    public static func send<Response>(
        currentToken: () -> String?,
        isExpired: (Response) -> Bool,
        renew: (_ expiredToken: String) async throws -> Void,
        request: (_ token: String) async throws -> Response
    ) async throws -> (response: Response, token: String)? {
        guard let token = currentToken() else { return nil }
        let response = try await request(token)
        guard isExpired(response) else { return (response, token) }

        // `renew` does nothing when another request on the shared session already replaced the token.
        try await renew(token)
        guard let renewed = currentToken() else { return nil }
        return (try await request(renewed), renewed)
    }
}
