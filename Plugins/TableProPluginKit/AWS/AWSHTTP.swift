import Foundation

public enum AWSHTTP {
    public static let requestTimeout: TimeInterval = 15
    public static let resourceTimeout: TimeInterval = 30

    public static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: configuration)
    }()
}
