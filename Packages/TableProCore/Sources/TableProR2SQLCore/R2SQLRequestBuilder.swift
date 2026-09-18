import Foundation

public enum R2SQLRequestBuilder {
    public static func queryRequest(
        config: R2SQLConnectionConfig,
        sql: String,
        timeoutInterval: TimeInterval
    ) throws -> R2SQLHTTPRequest {
        let url = try config.validated()
        let body = try JSONEncoder().encode(R2SQLRequestBody(query: sql))
        return R2SQLHTTPRequest(
            url: url,
            headers: [
                "Authorization": "Bearer \(config.token)",
                "Content-Type": "application/json",
                "Accept": "application/json"
            ],
            body: body,
            timeoutInterval: timeoutInterval
        )
    }
}
