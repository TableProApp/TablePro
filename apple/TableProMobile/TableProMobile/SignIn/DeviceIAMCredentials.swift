import Foundation
import os
import TableProDatabase
import TableProPluginKit

// Never in `additionalFields`, which syncs to the Mac and redials an open connection.
nonisolated struct DeviceIAMCredentials: Codable, Equatable, Sendable {
    var accessKeyId = ""
    var secretAccessKey = ""
    var sessionToken = ""
    var serviceAccountKey = ""
    var ssoStartUrl = ""
    var ssoRegion = ""
    var ssoAccountId = ""
    var ssoRoleName = ""

    private static let logger = Logger(subsystem: "com.TablePro", category: "DeviceIAMCredentials")

    nonisolated private enum CodingKeys: String, CodingKey {
        case accessKeyId, secretAccessKey, sessionToken, serviceAccountKey
        case ssoStartUrl, ssoRegion, ssoAccountId, ssoRoleName
    }

    var isEmpty: Bool {
        self == DeviceIAMCredentials()
    }

    var awsCredentials: AWSCredentials? {
        let id = Self.trimmed(accessKeyId)
        let secret = Self.trimmed(secretAccessKey)
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        let token = Self.trimmed(sessionToken)
        return AWSCredentials(accessKeyId: id, secretAccessKey: secret, sessionToken: token.isEmpty ? nil : token)
    }

    var ssoSettings: AWSSSOProfileSettings? {
        let startUrl = Self.trimmed(ssoStartUrl)
        let region = Self.trimmed(ssoRegion)
        let accountId = Self.trimmed(ssoAccountId)
        let roleName = Self.trimmed(ssoRoleName)
        guard !startUrl.isEmpty, !region.isEmpty, !accountId.isEmpty, !roleName.isEmpty else { return nil }
        return AWSSSOProfileSettings(
            accountId: accountId,
            roleName: roleName,
            startUrl: startUrl,
            region: region,
            ssoSession: nil
        )
    }

    static func account(for connectionId: UUID) -> String {
        ConnectionSecretKind.deviceIAM.account(for: connectionId)
    }

    static func load(for connectionId: UUID, from store: any SecureStore) throws -> DeviceIAMCredentials {
        guard let stored = try store.retrieve(forKey: account(for: connectionId)), !stored.isEmpty else {
            return DeviceIAMCredentials()
        }
        do {
            return try JSONDecoder().decode(DeviceIAMCredentials.self, from: Data(stored.utf8))
        } catch {
            logger.error("The device sign-in settings of \(connectionId.uuidString, privacy: .public) do not decode")
            return DeviceIAMCredentials()
        }
    }

    func save(for connectionId: UUID, to store: any SecureStore) throws {
        let account = Self.account(for: connectionId)
        guard !isEmpty else {
            try store.delete(forKey: account)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try store.store(String(decoding: try encoder.encode(self), as: UTF8.self), forKey: account)
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// In an extension, so the memberwise init stays.
nonisolated extension DeviceIAMCredentials {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys) throws -> String {
            try container.decodeIfPresent(String.self, forKey: key) ?? ""
        }
        self.init(
            accessKeyId: try value(.accessKeyId),
            secretAccessKey: try value(.secretAccessKey),
            sessionToken: try value(.sessionToken),
            serviceAccountKey: try value(.serviceAccountKey),
            ssoStartUrl: try value(.ssoStartUrl),
            ssoRegion: try value(.ssoRegion),
            ssoAccountId: try value(.ssoAccountId),
            ssoRoleName: try value(.ssoRoleName)
        )
    }
}
