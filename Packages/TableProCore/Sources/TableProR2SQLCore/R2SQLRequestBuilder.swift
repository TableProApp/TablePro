import Foundation

public enum R2SQLRequestBuilder {
    public static func queryRequest(config: R2SQLConnectionConfig, sql: String) throws -> R2SQLHTTPRequest {
        if let error = config.validate() {
            throw error
        }
        guard let url = config.queryURL else {
            throw R2SQLError.configuration(R2SQLErrorText.invalidEndpoint)
        }
        let body = R2SQLRequestBody(warehouse: config.warehouse, query: sql)
        guard let encoded = try? JSONEncoder().encode(body) else {
            throw R2SQLError.configuration("Could not encode the query request")
        }
        return R2SQLHTTPRequest(
            url: url,
            headers: [
                "Authorization": "Bearer \(config.token)",
                "Content-Type": "application/json",
                "Accept": "application/json"
            ],
            body: encoded,
            timeoutSeconds: config.timeoutSeconds
        )
    }
}
