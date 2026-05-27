//
//  AWSCredentialResolver.swift
//  TablePro
//

import Foundation

enum AWSCredentialResolver {
    static func resolve(source: String, fields: [String: String]) async throws -> AWSCredentials {
        switch source {
        case "profile":
            return try await resolveProfile(fields: fields)
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

    private static func resolveProfile(fields: [String: String]) async throws -> AWSCredentials {
        let profileName = fields["awsProfileName"].flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        let settings = profileSettings(profileName: profileName)
        guard !settings.isEmpty else {
            throw AWSAuthError.profileIncomplete(profileName)
        }

        let accessKeyId = settings["aws_access_key_id"] ?? ""
        let secretAccessKey = settings["aws_secret_access_key"] ?? ""
        if !accessKeyId.isEmpty, !secretAccessKey.isEmpty {
            let sessionToken = settings["aws_session_token"]
            return AWSCredentials(
                accessKeyId: accessKeyId,
                secretAccessKey: secretAccessKey,
                sessionToken: sessionToken?.isEmpty == true ? nil : sessionToken
            )
        }

        if let command = settings["credential_process"], !command.isEmpty {
            return try await runCredentialProcess(command, profileName: profileName)
        }

        throw AWSAuthError.profileIncomplete(profileName)
    }

    private static func profileSettings(profileName: String) -> [String: String] {
        var settings: [String: String] = [:]

        let configPath = NSString("~/.aws/config").expandingTildeInPath
        if let content = try? String(contentsOfFile: configPath, encoding: .utf8) {
            let sections = AWSSSO.parseIniSections(content)
            let sectionKey = profileName == "default" ? "default" : "profile \(profileName)"
            if let section = sections[sectionKey] {
                settings.merge(section) { _, new in new }
            }
        }

        let credentialsPath = NSString("~/.aws/credentials").expandingTildeInPath
        if let content = try? String(contentsOfFile: credentialsPath, encoding: .utf8) {
            let sections = AWSSSO.parseIniSections(content)
            if let section = sections[profileName] {
                settings.merge(section) { _, new in new }
            }
        }

        return settings
    }

    private static func runCredentialProcess(_ command: String, profileName: String) async throws -> AWSCredentials {
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
    }

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

    static func tokenizeCommand(_ command: String) -> [String] {
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

        enum CodingKeys: String, CodingKey {
            case version = "Version"
            case accessKeyId = "AccessKeyId"
            case secretAccessKey = "SecretAccessKey"
            case sessionToken = "SessionToken"
        }
    }

    static func parseCredentialProcessOutput(_ data: Data, profileName: String) throws -> AWSCredentials {
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
            sessionToken: output.sessionToken?.isEmpty == true ? nil : output.sessionToken
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
