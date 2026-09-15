import Foundation

public enum AWSProfileKind: String, Sendable, Equatable {
    case singleSignOn
    case assumeRole
    case accessKey
    case credentialProcess
    case webIdentity
    case unknown
}

public enum AWSProfileCredentialSource: Sendable, Equatable {
    case webIdentity
    case assumeRole(roleArn: String)
    case singleSignOn
    case staticKeys
    case credentialProcess(command: String)
    case undeclared

    public var kind: AWSProfileKind {
        switch self {
        case .webIdentity: .webIdentity
        case .assumeRole: .assumeRole
        case .singleSignOn: .singleSignOn
        case .staticKeys: .accessKey
        case .credentialProcess: .credentialProcess
        case .undeclared: .unknown
        }
    }
}

public enum AWSCredentialResolver {
    public static func credentialSource(for settings: [String: String]) -> AWSProfileCredentialSource {
        if settings["web_identity_token_file"]?.isEmpty == false {
            return .webIdentity
        }
        if let roleArn = settings["role_arn"], !roleArn.isEmpty {
            return .assumeRole(roleArn: roleArn)
        }
        if declaresSSO(settings) {
            return .singleSignOn
        }
        if staticCredentials(from: settings) != nil {
            return .staticKeys
        }
        if let command = settings["credential_process"], !command.isEmpty {
            return .credentialProcess(command: command)
        }
        return .undeclared
    }

    public static func profileKind(named profileName: String) -> AWSProfileKind {
        credentialSource(for: settings(forProfile: profileName)).kind
    }

    public static func profileRegion(named profileName: String) -> String? {
        guard let region = settings(forProfile: profileName)["region"], !region.isEmpty else { return nil }
        return region
    }

    private static func settings(forProfile profileName: String) -> [String: String] {
        AWSConfigFile.mergedProfileSettings(
            profileName: profileName,
            configContents: AWSConfigFile.readFile(AWSConfigFile.defaultConfigPath),
            credentialsContents: AWSConfigFile.readFile(AWSConfigFile.defaultCredentialsPath)
        )
    }

    public static func resolve(source: String, fields: [String: String]) async throws -> AWSCredentials {
        try await resolve(source: source, fields: fields, session: AWSHTTP.shared)
    }

    public static func resolve(
        source: String,
        fields: [String: String],
        session: URLSession
    ) async throws -> AWSCredentials {
        switch source {
        case "profile", "sso":
            return try await resolveProfile(fields: fields, session: session)
        default:
            return try resolveAccessKey(fields: fields)
        }
    }

    public static func resolveProfile(
        named profileName: String,
        session: URLSession = AWSHTTP.shared
    ) async throws -> AWSCredentials {
        try await resolveProfileChain(profileName: profileName, depth: 0, session: session)
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

    private static func resolveProfile(fields: [String: String], session: URLSession) async throws -> AWSCredentials {
        let profileName = fields["awsProfileName"].flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        return try await resolveProfileChain(profileName: profileName, depth: 0, session: session)
    }

    private static func resolveProfileChain(
        profileName: String,
        depth: Int,
        session: URLSession
    ) async throws -> AWSCredentials {
        guard depth < 5 else {
            throw AWSAuthError.assumeRoleChainTooDeep(profileName)
        }

        let settings = AWSConfigFile.mergedProfileSettings(
            profileName: profileName,
            configContents: AWSConfigFile.readFile(AWSConfigFile.defaultConfigPath),
            credentialsContents: AWSConfigFile.readFile(AWSConfigFile.defaultCredentialsPath)
        )
        guard !settings.isEmpty else {
            throw AWSAuthError.profileIncomplete(profileName)
        }

        switch credentialSource(for: settings) {
        case .webIdentity:
            throw AWSAuthError.webIdentityUnsupported(profileName)

        case .assumeRole(let roleArn):
            if let mfaSerial = settings["mfa_serial"], !mfaSerial.isEmpty {
                throw AWSAuthError.mfaUnsupported(profileName)
            }
            let base = try await baseCredentials(
                for: settings,
                profileName: profileName,
                depth: depth,
                session: session
            )
            return try await AWSSTS.assumeRole(
                roleArn: roleArn,
                roleSessionName: settings["role_session_name"] ?? defaultSessionName(for: profileName),
                externalId: settings["external_id"],
                durationSeconds: settings["duration_seconds"].flatMap(Int.init),
                region: signingRegion(for: settings, roleArn: roleArn),
                baseCredentials: base,
                session: session
            )

        case .singleSignOn:
            return try await resolveSSO(profileName: profileName, session: session)

        case .staticKeys:
            guard let credentials = staticCredentials(from: settings) else {
                throw AWSAuthError.profileIncomplete(profileName)
            }
            return credentials

        case .credentialProcess(let command):
            return try await runCredentialProcess(command, profileName: profileName)

        case .undeclared:
            throw AWSAuthError.profileIncomplete(profileName)
        }
    }

    private static func declaresSSO(_ settings: [String: String]) -> Bool {
        let keys = ["sso_session", "sso_start_url", "sso_account_id", "sso_role_name"]
        return keys.contains { (settings[$0] ?? "").isEmpty == false }
    }

    public static func signingRegion(for settings: [String: String], roleArn: String? = nil) -> String {
        if let region = settings["region"], !region.isEmpty {
            return AWSPartition.canonicalRegion(region)
        }
        let partition = roleArn.flatMap(AWSPartition.resolve(arn:))
        let environment = ProcessInfo.processInfo.environment
        for key in ["AWS_REGION", "AWS_DEFAULT_REGION"] {
            guard let region = environment[key], !region.isEmpty else { continue }
            let canonical = AWSPartition.canonicalRegion(region)
            guard let partition, AWSPartition.resolve(region: canonical) != partition else {
                return canonical
            }
        }
        return partition?.defaultRegion ?? AWSPartition.standard.defaultRegion
    }

    public static func singleSignOnProfile(rootedAt profileName: String, depth: Int = 0) -> String? {
        guard depth < 5 else { return nil }
        let settings = settings(forProfile: profileName)
        switch credentialSource(for: settings) {
        case .singleSignOn:
            return profileName
        case .assumeRole:
            guard let source = settings["source_profile"], !source.isEmpty else { return nil }
            return singleSignOnProfile(rootedAt: source, depth: depth + 1)
        default:
            return nil
        }
    }

    private static func baseCredentials(
        for settings: [String: String],
        profileName: String,
        depth: Int,
        session: URLSession
    ) async throws -> AWSCredentials {
        if let sourceProfile = settings["source_profile"], !sourceProfile.isEmpty {
            return try await resolveProfileChain(profileName: sourceProfile, depth: depth + 1, session: session)
        }
        if let credentialSource = settings["credential_source"], !credentialSource.isEmpty {
            guard credentialSource == "Environment" else {
                throw AWSAuthError.credentialSourceUnsupported(profile: profileName, source: credentialSource)
            }
            return try environmentCredentials(profileName: profileName)
        }
        throw AWSAuthError.assumeRoleMissingSource(profileName)
    }

    private static func defaultSessionName(for profileName: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+=,.@-"
        )
        let cleaned = String(profileName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        let trimmed = String(cleaned.prefix(50))
        return "tablepro-\(trimmed.isEmpty ? "session" : trimmed)"
    }

    private static func staticCredentials(from settings: [String: String]) -> AWSCredentials? {
        let accessKeyId = settings["aws_access_key_id"] ?? ""
        let secretAccessKey = settings["aws_secret_access_key"] ?? ""
        guard !accessKeyId.isEmpty, !secretAccessKey.isEmpty else { return nil }
        let sessionToken = settings["aws_session_token"]
        return AWSCredentials(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken?.isEmpty == true ? nil : sessionToken
        )
    }

    private static func environmentCredentials(profileName: String) throws -> AWSCredentials {
        let environment = ProcessInfo.processInfo.environment
        let accessKeyId = environment["AWS_ACCESS_KEY_ID"] ?? ""
        let secretAccessKey = environment["AWS_SECRET_ACCESS_KEY"] ?? ""
        guard !accessKeyId.isEmpty, !secretAccessKey.isEmpty else {
            throw AWSAuthError.profileIncomplete(profileName)
        }
        let sessionToken = environment["AWS_SESSION_TOKEN"]
        return AWSCredentials(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken?.isEmpty == true ? nil : sessionToken
        )
    }

    private static func runCredentialProcess(_ command: String, profileName: String) async throws -> AWSCredentials {
        #if os(macOS)
        let arguments = tokenizeCommand(command)
        guard !arguments.isEmpty else {
            throw AWSAuthError.credentialProcessInvalid(profileName)
        }

        let output = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try executeCredentialProcess(arguments, profileName: profileName))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        return try parseCredentialProcessOutput(output, profileName: profileName)
        #else
        throw AWSAuthError.credentialProcessUnsupportedOnPlatform(profileName)
        #endif
    }

    #if os(macOS)
    private static func executeCredentialProcess(_ arguments: [String], profileName: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = processEnvironment()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw AWSAuthError.credentialProcessLaunchFailed(
                profile: profileName,
                underlying: error.localizedDescription
            )
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AWSAuthError.credentialProcessFailed(
                profile: profileName,
                status: Int(process.terminationStatus),
                message: message
            )
        }

        return output
    }

    private static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let inherited = environment["PATH"].map { [$0] } ?? []
        environment["PATH"] = (searchPaths + inherited).joined(separator: ":")
        return environment
    }
    #endif

    public static func tokenizeCommand(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false

        for character in command {
            switch character {
            case "\"":
                inQuotes.toggle()
                hasToken = true
            case " " where !inQuotes:
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
            default:
                current.append(character)
                hasToken = true
            }
        }

        if hasToken {
            tokens.append(current)
        }

        return tokens
    }

    private struct CredentialProcessOutput: Decodable {
        let version: Int
        let accessKeyId: String
        let secretAccessKey: String
        let sessionToken: String?
        let expiration: String?

        enum CodingKeys: String, CodingKey {
            case version = "Version"
            case accessKeyId = "AccessKeyId"
            case secretAccessKey = "SecretAccessKey"
            case sessionToken = "SessionToken"
            case expiration = "Expiration"
        }
    }

    public static func parseCredentialProcessOutput(_ data: Data, profileName: String) throws -> AWSCredentials {
        guard let output = try? JSONDecoder().decode(CredentialProcessOutput.self, from: data) else {
            throw AWSAuthError.credentialProcessBadOutput(profileName)
        }
        guard output.version == 1 else {
            throw AWSAuthError.credentialProcessUnsupportedVersion(profile: profileName, version: output.version)
        }
        guard !output.accessKeyId.isEmpty, !output.secretAccessKey.isEmpty else {
            throw AWSAuthError.credentialProcessBadOutput(profileName)
        }
        return AWSCredentials(
            accessKeyId: output.accessKeyId,
            secretAccessKey: output.secretAccessKey,
            sessionToken: output.sessionToken?.isEmpty == true ? nil : output.sessionToken,
            expiration: output.expiration.flatMap(parseISO8601)
        )
    }

    static func parseISO8601(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func resolveSSO(profileName: String, session: URLSession) async throws -> AWSCredentials {
        let cacheDir = NSString("~/.aws/sso/cache").expandingTildeInPath

        guard let configContent = AWSConfigFile.readFile(AWSConfigFile.defaultConfigPath) else {
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
            session: session
        )
        return AWSCredentials(
            accessKeyId: credentials.accessKeyId,
            secretAccessKey: credentials.secretAccessKey,
            sessionToken: credentials.sessionToken,
            expiration: credentials.expiration
        )
    }
}
