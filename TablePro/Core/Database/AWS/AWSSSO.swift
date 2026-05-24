//
//  AWSSSO.swift
//  TablePro
//
//  AWS SSO credential resolution: reads the OIDC access token from
//  ~/.aws/sso/cache/ and exchanges it for STS credentials via the SSO portal
//  GetRoleCredentials endpoint. Matches the flow used by AWS SDKs.
//

import CommonCrypto
import Foundation

struct AWSSSOProfileSettings: Equatable, Sendable {
    let accountId: String
    let roleName: String
    let startUrl: String
    let region: String
    let ssoSession: String?
}

struct AWSSSORoleCredentials: Equatable, Sendable {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String
}

enum AWSSSOError: Error, LocalizedError, Equatable {
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

    var errorDescription: String? {
        switch self {
        case .configReadFailed:
            return String(localized: "Cannot read ~/.aws/config.")
        case .profileNotFound(let profile):
            return String(format: String(localized: "Profile \"%@\" not found in ~/.aws/config."), profile)
        case .profileMissingFields(let profile):
            return String(
                format: String(localized: "Profile \"%@\" in ~/.aws/config is missing sso_account_id or sso_role_name."),
                profile
            )
        case .sessionNotFound(let profile, let session):
            return String(
                format: String(localized: "SSO session \"%@\" referenced by profile \"%@\" was not found in ~/.aws/config."),
                session, profile
            )
        case .sessionMissingFields(let session):
            return String(
                format: String(localized: "SSO session \"%@\" in ~/.aws/config is missing sso_start_url or sso_region."),
                session
            )
        case .profileMissingUrlOrRegion(let profile):
            return String(
                format: String(localized: "Profile \"%@\" in ~/.aws/config is missing sso_start_url or sso_region."),
                profile
            )
        case .tokenCacheNotFound(let profile):
            return String(
                format: String(localized: "SSO token cache not found for profile \"%@\". Run 'aws sso login --profile %@' first."),
                profile, profile
            )
        case .tokenCacheMalformed(let profile):
            return String(
                format: String(localized: "SSO token cache for profile \"%@\" is malformed. Run 'aws sso login --profile %@' to refresh."),
                profile, profile
            )
        case .tokenExpired(let profile), .sessionUnauthorized(let profile):
            return String(
                format: String(localized: "SSO session for profile \"%@\" has expired. Run 'aws sso login --profile %@' to refresh."),
                profile, profile
            )
        case .urlBuildFailed(let profile):
            return String(format: String(localized: "Failed to build the SSO portal URL for profile \"%@\"."), profile)
        case .networkFailure(let profile, let underlying):
            return String(
                format: String(localized: "Failed to reach the SSO portal for profile \"%@\": %@"),
                profile, underlying
            )
        case .invalidResponse(let profile):
            return String(format: String(localized: "Unexpected response from the SSO portal for profile \"%@\"."), profile)
        case .roleNotAccessible(let role, let account):
            return String(
                format: String(localized: "Role \"%@\" in account \"%@\" is not accessible via SSO. Check role permissions in IAM Identity Center."),
                role, account
            )
        case .portalError(let profile, let status):
            return String(
                format: String(localized: "SSO portal returned HTTP %lld for profile \"%@\"."),
                Int64(status), profile
            )
        case .responseDecodeFailed(let profile):
            return String(format: String(localized: "Failed to decode the SSO portal response for profile \"%@\"."), profile)
        case .credentialsAlreadyExpired(let profile):
            return String(
                format: String(localized: "SSO role credentials for profile \"%@\" were already expired. Run 'aws sso login --profile %@' to refresh."),
                profile, profile
            )
        }
    }
}

enum AWSSSO {
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

    static func parseProfileSettings(configContent: String, profileName: String) throws -> AWSSSOProfileSettings {
        let sections = parseIniSections(configContent)
        let profileSection = profileName == "default" ? "default" : "profile \(profileName)"

        guard let profile = sections[profileSection] else {
            throw AWSSSOError.profileNotFound(profileName)
        }

        guard let accountId = profile["sso_account_id"], let roleName = profile["sso_role_name"] else {
            throw AWSSSOError.profileMissingFields(profile: profileName)
        }

        let ssoSession = profile["sso_session"]
        let resolvedStartUrl: String
        let resolvedRegion: String

        if let sessionName = ssoSession {
            guard let session = sections["sso-session \(sessionName)"] else {
                throw AWSSSOError.sessionNotFound(profile: profileName, session: sessionName)
            }
            guard let startUrl = session["sso_start_url"], let region = session["sso_region"] else {
                throw AWSSSOError.sessionMissingFields(session: sessionName)
            }
            resolvedStartUrl = startUrl
            resolvedRegion = region
        } else {
            guard let startUrl = profile["sso_start_url"], let region = profile["sso_region"] else {
                throw AWSSSOError.profileMissingUrlOrRegion(profileName)
            }
            resolvedStartUrl = startUrl
            resolvedRegion = region
        }

        return AWSSSOProfileSettings(
            accountId: accountId,
            roleName: roleName,
            startUrl: resolvedStartUrl,
            region: resolvedRegion,
            ssoSession: ssoSession
        )
    }

    static func readAccessToken(
        cacheDirectory: String,
        settings: AWSSSOProfileSettings,
        profileName: String,
        now: Date = Date()
    ) throws -> String {
        let cacheKey = settings.ssoSession ?? settings.startUrl
        let cacheFileName = sha1Hex(Data(cacheKey.utf8)) + ".json"
        let cacheFilePath = (cacheDirectory as NSString).appendingPathComponent(cacheFileName)

        guard let data = FileManager.default.contents(atPath: cacheFilePath) else {
            throw AWSSSOError.tokenCacheNotFound(profile: profileName)
        }

        struct TokenCache: Decodable {
            let accessToken: String
            let expiresAt: String
        }

        let token: TokenCache
        do {
            token = try JSONDecoder().decode(TokenCache.self, from: data)
        } catch {
            throw AWSSSOError.tokenCacheMalformed(profile: profileName)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt = formatter.date(from: token.expiresAt) ?? ISO8601DateFormatter().date(from: token.expiresAt)
        if let expiresAt, expiresAt <= now {
            throw AWSSSOError.tokenExpired(profile: profileName)
        }

        return token.accessToken
    }

    static func fetchRoleCredentials(
        accessToken: String,
        settings: AWSSSOProfileSettings,
        profileName: String,
        session: URLSession,
        now: Date = Date()
    ) async throws -> AWSSSORoleCredentials {
        var components = URLComponents(string: "https://portal.sso.\(settings.region).amazonaws.com/federation/credentials")
        components?.queryItems = [
            URLQueryItem(name: "account_id", value: settings.accountId),
            URLQueryItem(name: "role_name", value: settings.roleName)
        ]
        guard let url = components?.url else {
            throw AWSSSOError.urlBuildFailed(profile: profileName)
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
            throw AWSSSOError.networkFailure(profile: profileName, underlying: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AWSSSOError.invalidResponse(profile: profileName)
        }

        switch http.statusCode {
        case 200:
            break
        case 401:
            throw AWSSSOError.sessionUnauthorized(profile: profileName)
        case 403:
            throw AWSSSOError.roleNotAccessible(role: settings.roleName, account: settings.accountId)
        default:
            throw AWSSSOError.portalError(profile: profileName, status: http.statusCode)
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
            throw AWSSSOError.responseDecodeFailed(profile: profileName)
        }

        let expiry = Date(timeIntervalSince1970: TimeInterval(envelope.roleCredentials.expiration) / 1_000)
        if expiry <= now {
            throw AWSSSOError.credentialsAlreadyExpired(profile: profileName)
        }

        return AWSSSORoleCredentials(
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
