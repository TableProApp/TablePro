//
//  ConnectionEditorEngine+Issues.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary
import TableProPluginKit
import TableProSSHConfig

extension ConnectionEditorEngine {
    private struct PendingIssue {
        let row: EditorRow
        let message: String
        var severity: FieldIssue.Severity = .error
        var fallbackRow: EditorRow?
    }

    // Every issue names a row the layout shows; one whose row is not on screen moves to its fallback or is dropped.
    static func issues(
        _ draft: ConnectionDraft,
        _ traits: ConnectionTypeTraits,
        _ context: EditorContext,
        layout: EditorLayout? = nil
    ) -> [FieldIssue] {
        let layout = layout ?? self.layout(draft, traits, context)
        var pending: [PendingIssue] = []
        pending += generalIssues(draft, traits, context, layout: layout)
        pending += transportIssues(draft, traits, context)
        pending += sslIssues(draft, traits)
        pending += optionIssues(draft, traits, layout: layout)

        var issues: [FieldIssue] = []
        for item in pending {
            let row = layout.contains(item.row) ? item.row : item.fallbackRow
            guard let row, let facet = layout.facet(containing: row) else { continue }
            let issue = FieldIssue(facet: facet, row: row, message: item.message, severity: item.severity)
            if !issues.contains(issue) {
                issues.append(issue)
            }
        }
        return issues
    }

    // MARK: - General

    private static func generalIssues(
        _ draft: ConnectionDraft,
        _ traits: ConnectionTypeTraits,
        _ context: EditorContext,
        layout: EditorLayout
    ) -> [PendingIssue] {
        var pending: [PendingIssue] = []
        if draft.database.trimmingCharacters(in: .whitespaces).isEmpty {
            switch traits.connectionMode {
            case .fileBased:
                pending.append(PendingIssue(row: .builtIn(.databaseFile), message: String(localized: "Database file path is required")))
            case .apiOnly where traits.showsBuiltInDatabaseField:
                pending.append(PendingIssue(row: .builtIn(.database), message: String(localized: "Database name is required")))
            default:
                break
            }
        }
        if let issue = portIssue(draft.portText) {
            pending.append(PendingIssue(row: .builtIn(.port), message: issue))
        }
        pending += pluginFieldIssues(draft, traits, context, layout: layout)
        pending += hostListIssues(draft, traits)
        if usesLocalSocket(draft, traits) {
            if let endpoint = localSocketEndpoint(draft, traits) {
                if let issue = endpoint.issue {
                    pending.append(PendingIssue(row: .builtIn(.localSocketPath), message: issue))
                }
            } else {
                pending.append(PendingIssue(
                    row: .builtIn(.localSocketPath),
                    message: String(format: String(localized: "%@ is required"), String(localized: "Socket"))
                ))
            }
        }
        if credentialProfileIsMissing(draft, context), !context.credentialProfilesLoadFailed {
            pending.append(PendingIssue(
                row: .builtIn(.credentialProfile),
                message: String(localized: "This connection uses a credential profile that isn't on this Mac."),
                severity: .warning
            ))
        }
        return pending
    }

    // A linked profile supplies its own secure fields at connect, so an empty copy here blocks nothing.
    private static func pluginFieldIssues(
        _ draft: ConnectionDraft,
        _ traits: ConnectionTypeTraits,
        _ context: EditorContext,
        layout: EditorLayout
    ) -> [PendingIssue] {
        let suppliedByProfile = Set(context.credentialProfile(draft.credentials.mode.profileId)?.secureFieldIds ?? [])
        var pending: [PendingIssue] = []
        for field in traits.fields where layout.contains(.plugin(fieldID: field.id)) {
            let row = EditorRow.plugin(fieldID: field.id)
            switch field.content {
            case .plain:
                let value = value(of: field, in: draft)
                if field.isRequired, !suppliedByProfile.contains(field.id),
                   value.trimmingCharacters(in: .whitespaces).isEmpty {
                    pending.append(PendingIssue(row: row, message: String(format: String(localized: "%@ is required"), field.label)))
                }
                if let rangeIssue = field.rangeIssue(in: draft.fieldValues[field.id] ?? "") {
                    pending.append(PendingIssue(row: row, message: rangeIssue))
                }
            case .loadableExtensions:
                let extensions = (try? LoadableExtensionList.decode(draft.fieldValues[field.id])) ?? []
                do {
                    try LoadableExtensionPreflight.validate(extensions)
                } catch let error as LoadableExtensionError {
                    pending.append(PendingIssue(row: row, message: error.failureReason ?? error.localizedDescription))
                } catch {
                    pending.append(PendingIssue(row: row, message: error.localizedDescription))
                }
            case .attachedDatabases:
                do {
                    try AttachedDatabaseList.validate(AttachedDatabaseList.decode(draft.fieldValues[field.id]))
                } catch let error as AttachedDatabaseError {
                    pending.append(PendingIssue(row: row, message: error.failureReason ?? error.localizedDescription))
                } catch {
                    pending.append(PendingIssue(row: row, message: error.localizedDescription))
                }
            @unknown default:
                break
            }
        }
        return pending
    }

    // A pasted https:// node is stored as host:port, and SSL Mode picks the scheme, so Disabled sends it over plain HTTP.
    private static func hostListIssues(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> [PendingIssue] {
        guard let hostList = traits.fields.endpointHostList else { return [] }
        let row = EditorRow.plugin(fieldID: hostList.id)
        let entries = (draft.fieldValues[hostList.id] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var pending = entries
            .filter { HostListEndpoint.parse($0, defaultPort: traits.defaultPort) == nil }
            .map { PendingIssue(row: row, message: String(format: String(localized: "“%@” is not a host or host:port"), $0)) }
        if traits.supportsSSL, draft.ssl.mode == .disabled, let secure = entries.first(where: HostListEndpoint.usesHTTPS) {
            pending.append(PendingIssue(
                row: .builtIn(.sslMode),
                message: String(format: String(localized: "%@ needs an SSL Mode other than Disabled"), secure),
                fallbackRow: row
            ))
        }
        return pending
    }

    // MARK: - Transports

    private static func transportIssues(
        _ draft: ConnectionDraft,
        _ traits: ConnectionTypeTraits,
        _ context: EditorContext
    ) -> [PendingIssue] {
        switch draft.transport {
        case .ssh, .remoteFile:
            return sshIssues(draft, context)
        case .cloudflare:
            return cloudflareIssues(draft.cloudflare)
        case .cloudSQLProxy:
            return cloudSQLIssues(draft.cloudSQLProxy)
        case .socksProxy:
            var pending: [PendingIssue] = []
            if draft.socksProxy.host.trimmingCharacters(in: .whitespaces).isEmpty {
                pending.append(PendingIssue(row: .builtIn(.socksHost), message: String(localized: "SOCKS proxy host is required")))
            }
            if parsePort(draft.socksProxy.port) == nil {
                pending.append(PendingIssue(
                    row: .builtIn(.socksPort),
                    message: String(localized: "SOCKS proxy port must be between 1 and 65535")
                ))
            }
            return pending
        case .tunnelCommand:
            let row: BuiltInRow
            switch draft.tunnelCommand.config.method {
            case .kubectl: row = .kubernetesResource
            case .awsSSM: row = .awsTarget
            case .custom: row = .tunnelCommand
            }
            return TunnelCommandBuilder.validationIssues(for: draft.tunnelCommand.trimmedConfiguration)
                .map { PendingIssue(row: .builtIn(row), message: $0) }
        case .remoteDatabaseSession, nil:
            return []
        }
    }

    private static func sshIssues(_ draft: ConnectionDraft, _ context: EditorContext) -> [PendingIssue] {
        var pending: [PendingIssue] = []
        let resolution = sshResolution(draft, context)
        switch resolution {
        case .inline:
            if draft.ssh.host.trimmingCharacters(in: .whitespaces).isEmpty {
                pending.append(PendingIssue(
                    row: .builtIn(.sshHost),
                    message: String(localized: "SSH host is required"),
                    fallbackRow: .builtIn(.sshConfigHost)
                ))
            }
            if !draft.ssh.port.isEmpty, parsePort(draft.ssh.port) == nil {
                pending.append(PendingIssue(row: .builtIn(.sshPort), message: String(localized: "SSH port must be between 1 and 65535")))
            }
            for jumpHost in draft.ssh.jumpHosts where !jumpHost.isValid {
                pending.append(PendingIssue(
                    row: .builtIn(.jumpHost(jumpHost.id)),
                    message: String(localized: "Jump host configuration is invalid")
                ))
            }
        case .unresolvedProfile:
            if !context.sshProfilesLoadFailed {
                pending.append(PendingIssue(
                    row: .builtIn(.sshProfileMissing),
                    message: String(localized: "The SSH profile this connection uses isn't on this Mac."),
                    severity: .warning
                ))
            }
        case .profile, .disabled:
            break
        }
        guard draft.transport == .remoteFile else { return pending }
        if draft.ssh.profileId != nil {
            let host: String
            switch resolution {
            case .profile(let profile): host = profile.host
            case .unresolvedProfile(_, let snapshot): host = snapshot.host
            case .inline, .disabled: host = draft.ssh.host
            }
            if host.trimmingCharacters(in: .whitespaces).isEmpty {
                pending.append(PendingIssue(row: .builtIn(.sshProfile), message: String(localized: "SSH host is required")))
            }
        }
        if draft.ssh.remoteFilePath.trimmingCharacters(in: .whitespaces).isEmpty {
            pending.append(PendingIssue(
                row: .builtIn(.remoteFilePath),
                message: String(localized: "Remote database file path is required")
            ))
        }
        return pending
    }

    private static func cloudflareIssues(_ cloudflare: CloudflareDraft) -> [PendingIssue] {
        var pending: [PendingIssue] = []
        if cloudflare.accessHostname.trimmingCharacters(in: .whitespaces).isEmpty {
            pending.append(PendingIssue(row: .builtIn(.cloudflareHostname), message: String(localized: "Cloudflare hostname is required")))
        }
        if !cloudflare.automaticPort, parsePort(cloudflare.localPort) == nil {
            pending.append(PendingIssue(
                row: .builtIn(.cloudflareLocalPort),
                message: String(localized: "Local port must be between 1 and 65535")
            ))
        }
        if cloudflare.authMethod == .serviceToken,
           cloudflare.serviceTokenId.trimmingCharacters(in: .whitespaces).isEmpty
            || cloudflare.serviceTokenSecret.trimmingCharacters(in: .whitespaces).isEmpty {
            pending.append(PendingIssue(
                row: .builtIn(.cloudflareTokenId),
                message: String(localized: "Service token ID and secret are required")
            ))
        }
        return pending
    }

    private static func cloudSQLIssues(_ proxy: CloudSQLProxyDraft) -> [PendingIssue] {
        var pending: [PendingIssue] = []
        if !proxy.configuration.isValid {
            pending.append(PendingIssue(
                row: .builtIn(.cloudSQLInstance),
                message: String(localized: "Instance connection name must be project:region:instance")
            ))
        }
        if !proxy.automaticPort, parsePort(proxy.localPort) == nil {
            pending.append(PendingIssue(
                row: .builtIn(.cloudSQLLocalPort),
                message: String(localized: "Local port must be between 1 and 65535")
            ))
        }
        if proxy.authMode == .serviceAccountKey, !proxy.hasServiceAccountKey {
            pending.append(PendingIssue(
                row: .builtIn(.cloudSQLServiceAccountKey),
                message: String(localized: "A service account key is required")
            ))
        }
        return pending
    }

    // MARK: - SSL

    private static func sslIssues(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> [PendingIssue] {
        guard showsSSL(draft, traits) else { return [] }
        var pending: [PendingIssue] = []
        let mode = draft.ssl.mode
        if !offeredSSLModes(draft, traits).contains(mode) {
            let message = traits.ssl.supportedModes.contains(mode)
                ? String(format: String(localized: "The %1$@ driver cannot use SSL Mode %2$@ through a tunnel."), traits.displayName, mode.displayLabel)
                : String(format: String(localized: "The %1$@ driver does not support SSL Mode %2$@."), traits.displayName, mode.displayLabel)
            pending.append(PendingIssue(row: .builtIn(.sslMode), message: message))
        }
        guard traits.ssl.supportsPerConnectionCertificatePaths else { return pending }
        if traits.ssl.requiresCACertificate(for: mode), draft.ssl.caCertPath.trimmingCharacters(in: .whitespaces).isEmpty {
            pending.append(PendingIssue(
                row: .builtIn(.sslCACertificate),
                message: String(localized: "CA certificate is required for verification modes")
            ))
        }
        let hasClientCert = !draft.ssl.clientCertPath.trimmingCharacters(in: .whitespaces).isEmpty
        let hasClientKey = !draft.ssl.clientKeyPath.trimmingCharacters(in: .whitespaces).isEmpty
        if hasClientCert, !hasClientKey {
            pending.append(PendingIssue(
                row: .builtIn(.sslClientKey),
                message: String(localized: "Client key is required when client certificate is set")
            ))
        }
        return pending
    }

    // MARK: - Options

    private static func optionIssues(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits, layout: EditorLayout) -> [PendingIssue] {
        var pending: [PendingIssue] = []
        let options = draft.options
        if let seconds = options.connectTimeoutSeconds, !DatabaseConnection.connectTimeoutSecondsRange.contains(seconds) {
            pending.append(PendingIssue(
                row: .builtIn(.connectTimeout),
                message: String(localized: "Connect timeout must be between 1 and 600 seconds.")
            ))
        }
        if let seconds = options.queryTimeoutSeconds, !DatabaseConnection.queryTimeoutSecondsRange.contains(seconds) {
            pending.append(PendingIssue(
                row: .builtIn(.queryTimeout),
                message: String(localized: "Query timeout must be between 0 and 2,147,483 seconds.")
            ))
        }
        if let kilobytes = options.binaryInlineLimitKilobytes,
           !DatabaseConnection.binaryInlineLimitKilobytesRange.contains(kilobytes) {
            pending.append(PendingIssue(
                row: .builtIn(.binaryInlineLimit),
                message: String(localized: "Binary values limit must be between 1 and 1,048,576 KB.")
            ))
        }
        if let seconds = options.scriptTimeoutSeconds, !ConnectionScriptRunner.timeoutSecondsRange.contains(seconds) {
            pending.append(PendingIssue(
                row: .builtIn(.scriptTimeout),
                message: String(localized: "Script timeout must be between 1 and 300 seconds.")
            ))
        }
        return pending
    }
}
