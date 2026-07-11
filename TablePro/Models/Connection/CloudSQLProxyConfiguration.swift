//
//  CloudSQLProxyConfiguration.swift
//  TablePro
//

import Foundation

enum CloudSQLProxyAuthMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case applicationDefault
    case serviceAccountKey

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .applicationDefault: return String(localized: "Application Default Credentials")
        case .serviceAccountKey: return String(localized: "Service Account Key")
        }
    }
}

struct CloudSQLProxyConfiguration: Codable, Hashable, Sendable {
    var instanceConnectionName: String = ""
    var authMode: CloudSQLProxyAuthMode = .applicationDefault
    var useIAMAuth: Bool = false
    var usePrivateIP: Bool = false
    var localPort: Int?
    var binaryPath: String = ""

    var isValid: Bool {
        let parts = instanceConnectionName.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty }
    }
}

extension CloudSQLProxyConfiguration {
    private enum CodingKeys: String, CodingKey {
        case instanceConnectionName, authMode, useIAMAuth, usePrivateIP, localPort, binaryPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instanceConnectionName = try container.decodeIfPresent(String.self, forKey: .instanceConnectionName) ?? ""
        authMode = try container.decodeIfPresent(CloudSQLProxyAuthMode.self, forKey: .authMode) ?? .applicationDefault
        useIAMAuth = try container.decodeIfPresent(Bool.self, forKey: .useIAMAuth) ?? false
        usePrivateIP = try container.decodeIfPresent(Bool.self, forKey: .usePrivateIP) ?? false
        localPort = try container.decodeIfPresent(Int.self, forKey: .localPort)
        binaryPath = try container.decodeIfPresent(String.self, forKey: .binaryPath) ?? ""
    }
}
