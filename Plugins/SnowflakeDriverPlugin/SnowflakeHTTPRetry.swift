//
//  SnowflakeHTTPRetry.swift
//  SnowflakeDriverPlugin
//
//  Transport retry matching the official Snowflake connectors: transient HTTP
//  statuses retry with decorrelated jitter, each attempt tags the URL with
//  retryCount, retryReason, and clientStartTime, and regenerates request_guid
//  while keeping requestId stable so the server can deduplicate.
//

import Foundation
import os

enum SnowflakeRetryPolicy {
    static let maxAttempts = 5
    static let baseDelay: Double = 1.0
    static let maxDelay: Double = 16.0

    static func isTransient(statusCode: Int) -> Bool {
        statusCode == 429 || statusCode == 408 || (500...599).contains(statusCode)
    }

    static func nextDelay(after previous: Double, using generator: inout some RandomNumberGenerator) -> Double {
        let upper = max(baseDelay, previous * 3)
        return min(maxDelay, Double.random(in: baseDelay...upper, using: &generator))
    }

    static func retriedURL(_ url: URL, retryCount: Int, retryReason: Int, clientStartTime: Int) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (components.queryItems ?? []).filter { item in
            !["retryCount", "retryReason", "clientStartTime", "request_guid"].contains(item.name)
        }
        items.append(URLQueryItem(name: "retryCount", value: String(retryCount)))
        items.append(URLQueryItem(name: "retryReason", value: String(retryReason)))
        items.append(URLQueryItem(name: "clientStartTime", value: String(clientStartTime)))
        items.append(URLQueryItem(name: "request_guid", value: UUID().uuidString.lowercased()))
        components.queryItems = items
        return components.url ?? url
    }
}

enum SnowflakeHTTPClient {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SnowflakeHTTPClient")

    static func send(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let clientStartTime = Int(Date().timeIntervalSince1970 * 1_000)
        var generator = SystemRandomNumberGenerator()
        var delay = SnowflakeRetryPolicy.baseDelay
        var lastError: Error?
        var lastReason = 0

        for attempt in 0..<SnowflakeRetryPolicy.maxAttempts {
            var attemptRequest = request
            if attempt > 0, let url = request.url {
                attemptRequest.url = SnowflakeRetryPolicy.retriedURL(
                    url, retryCount: attempt, retryReason: lastReason, clientStartTime: clientStartTime
                )
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay = SnowflakeRetryPolicy.nextDelay(after: delay, using: &generator)
            }

            do {
                let (data, response) = try await session.data(for: attemptRequest)
                guard let http = response as? HTTPURLResponse else {
                    throw SnowflakeError.invalidResponse("No HTTP response from Snowflake")
                }
                guard SnowflakeRetryPolicy.isTransient(statusCode: http.statusCode) else {
                    return (data, http)
                }
                lastReason = http.statusCode
                lastError = SnowflakeError.invalidResponse("Snowflake returned HTTP \(http.statusCode)")
                logger.warning("Transient HTTP \(http.statusCode, privacy: .public); attempt \(attempt + 1, privacy: .public) of \(SnowflakeRetryPolicy.maxAttempts, privacy: .public)")
            } catch let error as URLError where error.code != .cancelled {
                lastReason = 0
                lastError = error
                logger.warning("Transport error \(error.code.rawValue, privacy: .public); attempt \(attempt + 1, privacy: .public) of \(SnowflakeRetryPolicy.maxAttempts, privacy: .public)")
            }
        }

        throw lastError ?? SnowflakeError.invalidResponse("Snowflake request failed after retries")
    }
}
