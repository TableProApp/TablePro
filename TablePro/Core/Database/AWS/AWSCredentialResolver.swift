//
//  AWSCredentialResolver.swift
//  TablePro
//

import Foundation

enum AWSCredentialResolver {
    static func resolve(source: String, fields: [String: String]) async throws -> AWSCredentials {
        switch source {
        case "profile":
            return try resolveProfile(fields: fields)
        case "sso":
            return try await resolveSSO(fields: fields)
        default:
            return try resolveAccessKey(fields: fields)
        }
    }

    private static func resolveAccessKey(fields: [String: String]) throws -> AWSCredentials {
        let accessKeyId = fields["awsAccessKeyId"] ?? ""
        let secretAccessKey = fields["awsSecretAccessKey"] ?? ""
        let sessionToken = fields["awsSessionToken"]

        guard !accessKeyId.isEmpty, !secretAccessKey.isEmpty else {
            throw AWSAuthError.missingAccessKey
        }

        return AWSCredentials(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken?.isEmpty == true ? nil : sessionToken
        )
    }

    private static func resolveProfile(fields: [String: String]) throws -> AWSCredentials {
        let profileName = fields["awsProfileName"].flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        let credentialsPath = NSString("~/.aws/credentials").expandingTildeInPath

        guard let content = try? String(contentsOfFile: credentialsPath, encoding: .utf8) else {
            throw AWSAuthError.credentialsFileUnreadable
        }

        let sections = AWSSSO.parseIniSections(content)
        guard let profile = sections[profileName] else {
            throw AWSAuthError.profileIncomplete(profileName)
        }

        let accessKeyId = profile["aws_access_key_id"] ?? ""
        let secretAccessKey = profile["aws_secret_access_key"] ?? ""
        guard !accessKeyId.isEmpty, !secretAccessKey.isEmpty else {
            throw AWSAuthError.profileIncomplete(profileName)
        }

        return AWSCredentials(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: profile["aws_session_token"]
        )
    }

    private static func resolveSSO(fields: [String: String]) async throws -> AWSCredentials {
        let profileName = fields["awsProfileName"].flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        let configPath = NSString("~/.aws/config").expandingTildeInPath
        let cacheDir = NSString("~/.aws/sso/cache").expandingTildeInPath

        guard let configContent = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            throw AWSSSOError.configReadFailed
        }

        let settings = try AWSSSO.parseProfileSettings(configContent: configContent, profileName: profileName)
        let accessToken = try AWSSSO.readAccessToken(
            cacheDirectory: cacheDir,
            settings: settings,
            profileName: profileName
        )
        let credentials = try await AWSSSO.fetchRoleCredentials(
            accessToken: accessToken,
            settings: settings,
            profileName: profileName,
            session: URLSession.shared
        )
        return AWSCredentials(
            accessKeyId: credentials.accessKeyId,
            secretAccessKey: credentials.secretAccessKey,
            sessionToken: credentials.sessionToken
        )
    }
}
