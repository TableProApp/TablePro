//
//  DynamoDBSsoCredentials.swift
//  DynamoDBDriverPlugin
//
//  AWS SSO credential resolution: reads the OIDC access token from
//  ~/.aws/sso/cache/ and exchanges it for STS credentials via the SSO portal
//  GetRoleCredentials endpoint. Matches the flow used by AWS SDKs.
//

import CommonCrypto
import Foundation

struct SsoProfileSettings: Equatable, Sendable {
    let accountId: String
    let roleName: String
    let startUrl: String
    let region: String
    let ssoSession: String?
}

struct SsoRoleCredentials: Equatable, Sendable {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String
}

enum SsoCredentialError: Error, Equatable {
    case configReadFailed
    case profileNotFound(String)
    case profileMissingFields(profile: String)
    case sessionNotFound(profile: String, session: String)
    case sessionMissingFields(session: String)
    case profileMissingUrlOrRegion(String)
    case tokenCacheNotFound(profile: String)
    case tokenCacheMalformed(profile: String)
    case tokenExpired(profile: String)
    case urlBuildFailed(profile: String)
    case networkFailure(profile: String, underlying: String)
    case invalidResponse(profile: String)
    case sessionUnauthorized(profile: String)
    case roleNotAccessible(role: String, account: String)
    case portalError(profile: String, status: Int)
    case responseDecodeFailed(profile: String)
    case credentialsAlreadyExpired(profile: String)

    var userMessage: String {
        switch self {
        case .configReadFailed:
            return "Cannot read ~/.aws/config"
        case .profileNotFound(let profile):
            return "Profile '\(profile)' not found in ~/.aws/config"
        case .profileMissingFields(let profile):
            return "Profile '\(profile)' in ~/.aws/config is missing sso_account_id or sso_role_name"
        case .sessionNotFound(let profile, let session):
            return "SSO session '\(session)' referenced by profile '\(profile)' not found in ~/.aws/config"
        case .sessionMissingFields(let session):
            return "SSO session '\(session)' in ~/.aws/config is missing sso_start_url or sso_region"
        case .profileMissingUrlOrRegion(let profile):
            return "Profile '\(profile)' in ~/.aws/config is missing sso_start_url or sso_region (required for legacy SSO)"
        case .tokenCacheNotFound(let profile):
            return "SSO token cache not found for profile '\(profile)'. Run 'aws sso login --profile \(profile)' first."
        case .tokenCacheMalformed(let profile):
            return "SSO token cache for profile '\(profile)' is malformed. Run 'aws sso login --profile \(profile)' to refresh."
        case .tokenExpired(let profile), .sessionUnauthorized(let profile):
            return "SSO session for profile '\(profile)' has expired. Run 'aws sso login --profile \(profile)' to refresh."
        case .urlBuildFailed(let profile):
            return "Failed to build SSO portal URL for profile '\(profile)'"
        case .networkFailure(let profile, let underlying):
            return "Failed to reach SSO portal for profile '\(profile)': \(underlying)"
        case .invalidResponse(let profile):
            return "Unexpected response from SSO portal for profile '\(profile)'"
        case .roleNotAccessible(let role, let account):
            return "Role '\(role)' in account '\(account)' is not accessible via SSO. Check role permissions in AWS IAM Identity Center."
        case .portalError(let profile, let status):
            return "SSO portal returned HTTP \(status) for profile '\(profile)'"
        case .responseDecodeFailed(let profile):
            return "Failed to decode SSO portal response for profile '\(profile)'"
        case .credentialsAlreadyExpired(let profile):
            return "SSO role credentials for profile '\(profile)' were already expired on arrival. Run 'aws sso login --profile \(profile)' to refresh."
        }
    }
}

enum DynamoDBSso {
    static func parseIniSections(_ content: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var current = ""

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { continue }

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                current = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if sections[current] == nil {
                    sections[current] = [:]
                }
                continue
            }

            guard !current.isEmpty else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }

            sections[current, default: [:]][parts[0]] = parts[1]
        }

        return sections
    }

    static func parseProfileSettings(configContent: String, profileName: String) throws -> SsoProfileSettings {
        let sections = parseIniSections(configContent)
        let profileSection = profileName == "default" ? "default" : "profile \(profileName)"

        guard let profile = sections[profileSection] else {
            throw SsoCredentialError.profileNotFound(profileName)
        }

        guard let accountId = profile["sso_account_id"], let roleName = profile["sso_role_name"] else {
            throw SsoCredentialError.profileMissingFields(profile: profileName)
        }

        let ssoSession = profile["sso_session"]
        let resolvedStartUrl: String
        let resolvedRegion: String

        if let sessionName = ssoSession {
            guard let session = sections["sso-session \(sessionName)"] else {
                throw SsoCredentialError.sessionNotFound(profile: profileName, session: sessionName)
            }
            guard let startUrl = session["sso_start_url"], let region = session["sso_region"] else {
                throw SsoCredentialError.sessionMissingFields(session: sessionName)
            }
            resolvedStartUrl = startUrl
            resolvedRegion = region
        } else {
            guard let startUrl = profile["sso_start_url"], let region = profile["sso_region"] else {
                throw SsoCredentialError.profileMissingUrlOrRegion(profileName)
            }
            resolvedStartUrl = startUrl
            resolvedRegion = region
        }

        return SsoProfileSettings(
            accountId: accountId,
            roleName: roleName,
            startUrl: resolvedStartUrl,
            region: resolvedRegion,
            ssoSession: ssoSession
        )
    }

    static func readAccessToken(
        cacheDirectory: String,
        settings: SsoProfileSettings,
        profileName: String,
        now: Date = Date()
    ) throws -> String {
        let cacheKey = settings.ssoSession ?? settings.startUrl
        let cacheFileName = sha1Hex(Data(cacheKey.utf8)) + ".json"
        let cacheFilePath = (cacheDirectory as NSString).appendingPathComponent(cacheFileName)

        guard let data = FileManager.default.contents(atPath: cacheFilePath) else {
            throw SsoCredentialError.tokenCacheNotFound(profile: profileName)
        }

        struct TokenCache: Decodable {
            let accessToken: String
            let expiresAt: String
        }

        let token: TokenCache
        do {
            token = try JSONDecoder().decode(TokenCache.self, from: data)
        } catch {
            throw SsoCredentialError.tokenCacheMalformed(profile: profileName)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt = formatter.date(from: token.expiresAt) ?? ISO8601DateFormatter().date(from: token.expiresAt)
        if let expiresAt, expiresAt <= now {
            throw SsoCredentialError.tokenExpired(profile: profileName)
        }

        return token.accessToken
    }

    static func fetchRoleCredentials(
        accessToken: String,
        settings: SsoProfileSettings,
        profileName: String,
        session: URLSession,
        now: Date = Date()
    ) async throws -> SsoRoleCredentials {
        var components = URLComponents(string: "https://portal.sso.\(settings.region).amazonaws.com/federation/credentials")
        components?.queryItems = [
            URLQueryItem(name: "account_id", value: settings.accountId),
            URLQueryItem(name: "role_name", value: settings.roleName)
        ]
        guard let url = components?.url else {
            throw SsoCredentialError.urlBuildFailed(profile: profileName)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(accessToken, forHTTPHeaderField: "x-amz-sso_bearer_token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SsoCredentialError.networkFailure(profile: profileName, underlying: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SsoCredentialError.invalidResponse(profile: profileName)
        }

        switch http.statusCode {
        case 200:
            break
        case 401:
            throw SsoCredentialError.sessionUnauthorized(profile: profileName)
        case 403:
            throw SsoCredentialError.roleNotAccessible(role: settings.roleName, account: settings.accountId)
        default:
            throw SsoCredentialError.portalError(profile: profileName, status: http.statusCode)
        }

        struct RoleCredentialsEnvelope: Decodable {
            struct RoleCredentials: Decodable {
                let accessKeyId: String
                let secretAccessKey: String
                let sessionToken: String
                let expiration: Int64
            }
            let roleCredentials: RoleCredentials
        }

        let envelope: RoleCredentialsEnvelope
        do {
            envelope = try JSONDecoder().decode(RoleCredentialsEnvelope.self, from: data)
        } catch {
            throw SsoCredentialError.responseDecodeFailed(profile: profileName)
        }

        let expiry = Date(timeIntervalSince1970: TimeInterval(envelope.roleCredentials.expiration) / 1_000)
        if expiry <= now {
            throw SsoCredentialError.credentialsAlreadyExpired(profile: profileName)
        }

        return SsoRoleCredentials(
            accessKeyId: envelope.roleCredentials.accessKeyId,
            secretAccessKey: envelope.roleCredentials.secretAccessKey,
            sessionToken: envelope.roleCredentials.sessionToken
        )
    }

    static func sha1Hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
