//
//  ClickHouseCredentials.swift
//  ClickHouseDriverPlugin
//

import Foundation

internal enum ClickHouseCredentials {
    internal static let defaultUsername = "default"

    internal static func effectiveUsername(_ username: String) -> String {
        username.isEmpty ? defaultUsername : username
    }

    internal static func basicAuthorizationHeader(username: String, password: String) -> String? {
        let credentials = "\(effectiveUsername(username)):\(password)"
        guard let data = credentials.data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }
}
