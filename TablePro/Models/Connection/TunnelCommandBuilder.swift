//
//  TunnelCommandBuilder.swift
//  TablePro
//

import Foundation

/// Turns a tunnel command configuration into the exact argument vector TablePro will run.
///
/// Preset flags are written in `--flag=value` form so a value can never be read as a flag of its
/// own, and the two positional arguments a preset still needs are validated instead. That is why
/// a preset carries parameters rather than code: nothing a preset field holds can add an argument.
enum TunnelCommandBuilder {
    struct Invocation: Equatable, Sendable {
        let executable: String
        let arguments: [String]
    }

    private static let sessionDocument = "AWS-StartPortForwardingSessionToRemoteHost"

    static func invocation(
        for config: TunnelCommandConfiguration,
        localPort: Int,
        remoteHost: String,
        remotePort: Int
    ) throws -> Invocation {
        try invocation(
            for: config,
            localPortToken: String(localPort),
            remoteHost: remoteHost,
            remotePort: remotePort
        )
    }

    /// The command as the connection form shows it, with the local port left as its placeholder
    /// because it is allocated at connect time and naming a number here would be a lie.
    static func previewCommand(
        for config: TunnelCommandConfiguration,
        remoteHost: String,
        remotePort: Int
    ) -> String? {
        guard let invocation = try? invocation(
            for: config,
            localPortToken: TunnelCommandLine.localPortPlaceholder,
            remoteHost: remoteHost,
            remotePort: remotePort
        ) else { return nil }
        return ([invocation.executable] + invocation.arguments).map(displayQuoted).joined(separator: " ")
    }

    static func validationIssues(for config: TunnelCommandConfiguration) -> [String] {
        switch config.method {
        case .custom:
            return customValidationIssues(for: config)
        case .kubectl:
            return kubectlValidationIssues(for: config)
        case .awsSSM:
            return awsValidationIssues(for: config)
        }
    }

    // MARK: - Private: invocation

    private static func invocation(
        for config: TunnelCommandConfiguration,
        localPortToken: String,
        remoteHost: String,
        remotePort: Int
    ) throws -> Invocation {
        switch config.method {
        case .custom:
            /// `ParseError` carries no message of its own, so letting it escape would put
            /// "The operation couldn't be completed" in front of the user instead of the two
            /// `TunnelCommandError` cases written for exactly these failures.
            let tokens: [String]
            do {
                tokens = try TunnelCommandLine.tokenize(config.command)
            } catch TunnelCommandLine.ParseError.empty {
                throw TunnelCommandError.commandEmpty
            } catch {
                throw TunnelCommandError.unbalancedQuote
            }
            guard TunnelCommandLine.containsLocalPortPlaceholder(config.command) else {
                throw TunnelCommandError.missingLocalPortPlaceholder
            }
            let substituted = tokens.map { token in
                token
                    .replacingOccurrences(of: TunnelCommandLine.localPortPlaceholder, with: localPortToken)
                    .replacingOccurrences(of: TunnelCommandLine.hostPlaceholder, with: remoteHost)
                    .replacingOccurrences(of: TunnelCommandLine.remotePortPlaceholder, with: String(remotePort))
            }
            return Invocation(executable: substituted[0], arguments: Array(substituted.dropFirst()))
        case .kubectl:
            return Invocation(
                executable: executable(for: config),
                arguments: kubectlArguments(for: config, localPortToken: localPortToken, remotePort: remotePort)
            )
        case .awsSSM:
            return Invocation(
                executable: executable(for: config),
                arguments: awsArguments(
                    for: config,
                    localPortToken: localPortToken,
                    remoteHost: remoteHost,
                    remotePort: remotePort
                )
            )
        }
    }

    private static func executable(for config: TunnelCommandConfiguration) -> String {
        let path = config.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? config.method.executableName : (path as NSString).expandingTildeInPath
    }

    private static func kubectlArguments(
        for config: TunnelCommandConfiguration,
        localPortToken: String,
        remotePort: Int
    ) -> [String] {
        var arguments: [String] = []
        let context = trimmed(config.kubernetesContext)
        let namespace = trimmed(config.kubernetesNamespace)
        if !context.isEmpty { arguments.append("--context=\(context)") }
        if !namespace.isEmpty { arguments.append("--namespace=\(namespace)") }
        arguments.append("port-forward")
        arguments.append("--address=127.0.0.1")
        arguments.append(trimmed(config.kubernetesResource))
        arguments.append("\(localPortToken):\(remotePort)")
        return arguments
    }

    private static func awsArguments(
        for config: TunnelCommandConfiguration,
        localPortToken: String,
        remoteHost: String,
        remotePort: Int
    ) -> [String] {
        var arguments = [
            "ssm",
            "start-session",
            "--target=\(trimmed(config.awsTarget))",
            "--document-name=\(sessionDocument)",
            "--parameters=host=\(remoteHost),portNumber=\(remotePort),localPortNumber=\(localPortToken)"
        ]
        let profile = trimmed(config.awsProfile)
        let region = trimmed(config.awsRegion)
        if !profile.isEmpty { arguments.append("--profile=\(profile)") }
        if !region.isEmpty { arguments.append("--region=\(region)") }
        return arguments
    }

    // MARK: - Private: validation

    private static func customValidationIssues(for config: TunnelCommandConfiguration) -> [String] {
        var issues: [String] = []
        let command = trimmed(config.command)
        if command.isEmpty {
            issues.append(String(localized: "A command is required"))
            return issues
        }
        do {
            _ = try TunnelCommandLine.tokenize(command)
        } catch {
            issues.append(String(localized: "The command has an unclosed quote"))
        }
        if !TunnelCommandLine.containsLocalPortPlaceholder(command) {
            issues.append(String(
                format: String(localized: "The command must contain %@, where the local port goes"),
                TunnelCommandLine.localPortPlaceholder
            ))
        }
        return issues
    }

    private static func kubectlValidationIssues(for config: TunnelCommandConfiguration) -> [String] {
        var issues: [String] = []
        let resource = trimmed(config.kubernetesResource)
        if resource.isEmpty {
            issues.append(String(localized: "A Kubernetes resource is required, such as service/postgres"))
        }
        for (value, label) in [
            (resource, String(localized: "Resource")),
            (trimmed(config.kubernetesNamespace), String(localized: "Namespace")),
            (trimmed(config.kubernetesContext), String(localized: "Context"))
        ] where isFlagLike(value) {
            issues.append(flagLikeIssue(label))
        }
        return issues
    }

    private static func awsValidationIssues(for config: TunnelCommandConfiguration) -> [String] {
        var issues: [String] = []
        let target = trimmed(config.awsTarget)
        if target.isEmpty {
            issues.append(String(localized: "An SSM target is required, such as i-0123456789abcdef0"))
        }
        for (value, label) in [
            (target, String(localized: "Target")),
            (trimmed(config.awsProfile), String(localized: "Profile")),
            (trimmed(config.awsRegion), String(localized: "Region"))
        ] where isFlagLike(value) {
            issues.append(flagLikeIssue(label))
        }
        return issues
    }

    /// A preset field reaches the command as one argument, so a value opening with a dash would be
    /// read as a flag and a value carrying a space would become two arguments.
    private static func isFlagLike(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if value.hasPrefix("-") { return true }
        return value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
    }

    private static func flagLikeIssue(_ label: String) -> String {
        String(
            format: String(localized: "%@ cannot start with a dash or contain spaces"),
            label
        )
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func displayQuoted(_ token: String) -> String {
        guard token.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else { return token }
        return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
