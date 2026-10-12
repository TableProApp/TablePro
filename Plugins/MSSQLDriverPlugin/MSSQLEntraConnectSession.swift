import Foundation

enum MSSQLEntraConnectSession {
    static let requestTimeout: TimeInterval = 600
    static let resourceTimeout: TimeInterval = 3_600

    static let shared = URLSession(configuration: configuration())

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }
}
