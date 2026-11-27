//
//  ConnectionEditorEngine+Layout.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSSHConfig
import TableProSSHTransport

extension ConnectionEditorEngine {
    static func layout(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits, _ context: EditorContext) -> EditorLayout {
        var facets = [generalFacet(draft, traits, context)]
        if availableTransports(draft, traits).count > 1 {
            facets.append(transportFacet(draft, traits, context))
        }
        if showsSSL(draft, traits) {
            facets.append(sslFacet(draft, traits))
        }
        facets.append(appearanceFacet())
        facets.append(safeModeFacet(draft, traits, context))
        facets.append(aiFacet(draft, context))
        facets.append(startupFacet())
        facets.append(advancedFacet(draft, traits, context))
        return EditorLayout(facets: facets, disabledRows: unusedRows(draft, traits))
    }

    private static func unusedRows(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> Set<EditorRow> {
        var rows: Set<EditorRow> = []
        if forwardsToUnixSocket(draft) {
            rows.formUnion([.builtIn(.host), .builtIn(.port)])
        }
        // Remote File swaps the local path for its own copy or session at connect.
        if draft.transport == .remoteFile {
            if case .additionalField(let fieldId) = traits.localFilePathField {
                rows.insert(.plugin(fieldID: fieldId))
            } else {
                rows.insert(.builtIn(.databaseFile))
            }
        }
        return rows
    }

    private static func pluginRows(
        _ fields: [ConnectionField],
        _ draft: ConnectionDraft,
        _ traits: ConnectionTypeTraits
    ) -> [EditorRow] {
        fields.filter { isVisible($0, draft, traits) }.map { .plugin(fieldID: $0.id) }
    }

    private static func isHostList(_ field: ConnectionField) -> Bool {
        if case .hostList = field.fieldType { return true }
        return false
    }

    // MARK: - General

    private static func generalFacet(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits, _ context: EditorContext) -> FacetLayout {
        var sections = [
            SectionLayout(
                id: "identity",
                title: nil,
                footer: nil,
                rows: [.builtIn(.name), .builtIn(.type), .builtIn(.environment)]
            )
        ]
        if let connection = connectionSection(draft, traits) {
            sections.append(connection)
        }
        if let authentication = authenticationSection(draft, traits) {
            sections.append(authentication)
        }
        return FacetLayout(facet: .general, title: ConnectionFacet.general.title, sections: sections)
    }

    private static func connectionSection(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> SectionLayout? {
        let connectionFields = traits.fields.filter { $0.section == .connection }
        switch traits.connectionMode {
        case .fileBased:
            return SectionLayout(
                id: "connection",
                title: String(localized: "Database File"),
                footer: draft.transport == .remoteFile
                    ? String(localized: "File Path is unused. The connection opens the file on the SSH server chosen in Location.")
                    : nil,
                rows: [.builtIn(.databaseFile)] + pluginRows(connectionFields, draft, traits)
            )
        case .apiOnly:
            var rows = pluginRows(connectionFields, draft, traits)
            if traits.showsBuiltInDatabaseField {
                rows.append(.builtIn(.database))
            }
            guard !rows.isEmpty else { return nil }
            return SectionLayout(id: "connection", title: String(localized: "Connection"), footer: nil, rows: rows)
        default:
            var rows: [EditorRow] = []
            if traits.supportsLocalSocket {
                rows.append(.builtIn(.endpointKind))
            }
            if usesLocalSocket(draft, traits) {
                rows.append(.builtIn(.localSocketPath))
                if traits.localSocketIsDirectory {
                    rows.append(.builtIn(.port))
                }
            } else {
                let hostLists = visibleHostListFields(draft, traits)
                if hostLists.isEmpty {
                    rows += [.builtIn(.host), .builtIn(.port)]
                    if showsPortTLSNotice(draft, traits) {
                        rows.append(.builtIn(.portTLSNotice))
                    }
                } else {
                    rows += hostLists.map { .plugin(fieldID: $0.id) }
                }
                rows += pluginRows(connectionFields.filter { !isHostList($0) }, draft, traits)
            }
            if traits.showsBuiltInDatabaseField {
                rows.append(.builtIn(.database))
            }
            var footer: String?
            if !usesLocalSocket(draft, traits), forwardsToUnixSocket(draft) {
                footer = String(localized: "Host and Port are unused. The SSH tunnel forwards to the socket path set in SSH & Proxies.")
            }
            return SectionLayout(id: "connection", title: String(localized: "Connection"), footer: footer, rows: rows)
        }
    }

    static func showsPortTLSNotice(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> Bool {
        guard traits.supportsSSL, let implied = traits.ssl.impliedMode(forPort: resolvedPort(draft, traits)) else {
            return false
        }
        return draft.ssl.mode == implied || draft.ssl.mode == .disabled
    }

    private static func authenticationSection(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> SectionLayout? {
        let authFields = traits.fields.filter { $0.section == .authentication }
        // A file has no sign-in, so a file type shows only what its plugin declares.
        guard traits.connectionMode != .fileBased else {
            let rows = pluginRows(authFields, draft, traits)
            guard !rows.isEmpty else { return nil }
            return SectionLayout(id: "authentication", title: String(localized: "Authentication"), footer: nil, rows: rows)
        }
        let split = authFields.splitCredentialControllers()
        guard !draft.credentials.usesProfile else {
            let rows: [EditorRow] = [.builtIn(.credentialProfile)] + pluginRows(split.rest, draft, traits)
            return SectionLayout(id: "authentication", title: String(localized: "Authentication"), footer: nil, rows: rows)
        }
        // Method, Credentials, Username, Password, then a switch that only stands in for the password (~/.pgpass):
        // the method decides what the rows under it are, so it leads, and the switch sits after what it replaces.
        let methods = (split.usernameControllers + split.passwordControllers).filter(isMethodPicker)
        var rows: [EditorRow] = pluginRows(methods, draft, traits) + [.builtIn(.credentialProfile)]
        rows += pluginRows(split.usernameControllers.filter { !isMethodPicker($0) }, draft, traits)
        if traits.connectionMode == .network, !hidesUsername(draft, traits) {
            rows.append(.builtIn(.username))
        }
        if !hidesPassword(draft, traits) {
            if draft.credentials.passwordSource != nil {
                if !draft.credentials.promptsForPassword {
                    rows.append(.builtIn(.passwordSource))
                }
                rows.append(.builtIn(.passwordMode))
            } else {
                rows.append(.builtIn(.passwordMode))
                if !draft.credentials.promptsForPassword {
                    rows.append(.builtIn(.password))
                }
            }
        }
        rows += pluginRows(split.rest, draft, traits)
        if showsKerberosNote(draft, traits) {
            rows.append(.builtIn(.kerberosNote))
        }
        rows += pluginRows(split.passwordControllers.filter { !isMethodPicker($0) }, draft, traits)
        if usesPgpass(draft, traits) {
            rows.append(.builtIn(.pgpassStatus))
        }
        return SectionLayout(id: "authentication", title: String(localized: "Authentication"), footer: nil, rows: rows)
    }

    private static func isMethodPicker(_ field: ConnectionField) -> Bool {
        if case .dropdown = field.fieldType { return true }
        return false
    }

    static let pgpassFieldId = "usePgpass"

    static func usesPgpass(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> Bool {
        traits.field(pgpassFieldId) != nil && draft.fieldValues[pgpassFieldId] == "true"
    }

    static func usesWindowsAuthentication(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> Bool {
        traits.pluginTypeId == "SQL Server" && draft.fieldValues["mssqlAuthMethod"] == "windows"
    }

    static func showsKerberosNote(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> Bool {
        usesWindowsAuthentication(draft, traits) || KerberosAuthFields.isSelected(in: draft.fieldValues)
    }

    // MARK: - SSH and proxies

    private static func transportFacet(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits, _ context: EditorContext) -> FacetLayout {
        var sections = [
            SectionLayout(
                id: "transport",
                title: nil,
                footer: transportSummary(draft, traits),
                rows: [.builtIn(.transport)]
            )
        ]
        switch draft.transport {
        case .ssh:
            sections += sshServerSections(draft, context)
            if traits.socketForwardApplies {
                sections.append(SectionLayout(
                    id: "forwardTo",
                    title: String(localized: "Forward To"),
                    footer: nil,
                    rows: [.builtIn(.sshForwardSocketPath)]
                ))
            }
        case .remoteFile:
            var rows: [EditorRow] = [.builtIn(.remoteFilePath)]
            if traits.supportsRemoteDatabaseSession {
                rows.append(.builtIn(.remoteFileAccess))
            }
            sections.append(SectionLayout(id: "remoteFile", title: String(localized: "Remote File"), footer: nil, rows: rows))
            sections += sshServerSections(draft, context)
        case .cloudflare:
            sections += cloudflareSections(draft)
        case .cloudSQLProxy:
            sections += cloudSQLSections(draft)
        case .socksProxy:
            sections += [
                SectionLayout(
                    id: "socksServer",
                    title: String(localized: "Proxy Server"),
                    footer: nil,
                    rows: [.builtIn(.socksHost), .builtIn(.socksPort)]
                ),
                SectionLayout(
                    id: "socksCredentials",
                    title: String(localized: "Credentials"),
                    footer: nil,
                    rows: [.builtIn(.socksUsername), .builtIn(.socksPassword)]
                )
            ]
        case .tunnelCommand:
            sections += tunnelCommandSections(draft)
        case .remoteDatabaseSession, nil:
            break
        }
        let title = traits.supportsRemoteDatabaseFile ? String(localized: "Location") : ConnectionFacet.sshAndProxies.title
        return FacetLayout(facet: .sshAndProxies, title: title, sections: sections)
    }

    static func transportSummary(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> String {
        if draft.transport == .remoteFile, traits.supportsRemoteDatabaseSession, draft.ssh.remoteFileAccess == .onServer {
            return ConnectionTunnelKind.remoteDatabaseSession.summary
        }
        if let transport = draft.transport {
            return transport.summary
        }
        return ConnectionTunnelKind.directSummary(
            isFileBased: traits.connectionMode == .fileBased,
            usesLocalSocket: usesLocalSocket(draft, traits),
            localSocketSkipsTLS: localSocketSkipsTLS(draft, traits)
        )
    }

    private static func sshServerSections(_ draft: ConnectionDraft, _ context: EditorContext) -> [SectionLayout] {
        var profileRows: [EditorRow] = [.builtIn(.sshProfile)]
        if sshProfileIsUnresolved(draft, context) {
            profileRows.append(.builtIn(.sshProfileMissing))
        }
        var sections = [SectionLayout(id: "sshProfile", title: String(localized: "Profile"), footer: nil, rows: profileRows)]
        guard draft.ssh.profileId == nil else { return sections }

        var serverRows: [EditorRow] = []
        if !context.sshConfigEntries.isEmpty {
            serverRows.append(.builtIn(.sshConfigHost))
        }
        if draft.ssh.selectedConfigHost.isEmpty {
            serverRows.append(.builtIn(.sshHost))
        }
        serverRows += [.builtIn(.sshPort), .builtIn(.sshUsername)]
        sections.append(SectionLayout(id: "sshServer", title: String(localized: "Server"), footer: nil, rows: serverRows))

        var authRows: [EditorRow] = [.builtIn(.sshAuthMethod)]
        switch draft.ssh.authMethod {
        case .password, .keyboardInteractive:
            authRows.append(.builtIn(.sshPassword))
        case .sshAgent:
            authRows += [.builtIn(.sshAgentSocket), .builtIn(.sshIdentityFile)]
        case .privateKey:
            authRows += [.builtIn(.sshKeyFile), .builtIn(.sshKeyPassphrase)]
        case .none:
            authRows.append(.builtIn(.sshNoAuthenticationNote))
        }
        sections.append(SectionLayout(id: "sshAuthentication", title: String(localized: "Authentication"), footer: nil, rows: authRows))

        if draft.ssh.authMethod.supportsTwoFactorAuthentication {
            var totpRows: [EditorRow] = [.builtIn(.sshTOTPMode)]
            if draft.ssh.totpMode == .autoGenerate {
                totpRows += [.builtIn(.sshTOTPSecret), .builtIn(.sshTOTPAlgorithm), .builtIn(.sshTOTPDigits), .builtIn(.sshTOTPPeriod)]
            }
            sections.append(SectionLayout(
                id: "sshTwoFactor",
                title: String(localized: "Two-Factor Authentication"),
                footer: nil,
                rows: totpRows
            ))
        }

        let jumpRows = draft.ssh.jumpHosts.map { EditorRow.builtIn(.jumpHost($0.id)) } + [.builtIn(.addJumpHost)]
        sections.append(SectionLayout(id: "sshJumpHosts", title: String(localized: "Jump Hosts"), footer: nil, rows: jumpRows))
        return sections
    }

    private static func cloudflareSections(_ draft: ConnectionDraft) -> [SectionLayout] {
        var authRows: [EditorRow] = [.builtIn(.cloudflareAuthMethod)]
        switch draft.cloudflare.authMethod {
        case .browserSSO:
            authRows.append(.builtIn(.cloudflareSignIn))
        case .serviceToken:
            authRows += [.builtIn(.cloudflareTokenId), .builtIn(.cloudflareTokenSecret)]
        }
        var listenerRows: [EditorRow] = [.builtIn(.cloudflareAutomaticPort)]
        if !draft.cloudflare.automaticPort {
            listenerRows.append(.builtIn(.cloudflareLocalPort))
        }
        listenerRows.append(.builtIn(.cloudflareExposeToLAN))
        return [
            SectionLayout(
                id: "cloudflareApplication",
                title: String(localized: "Access Application"),
                footer: nil,
                rows: [.builtIn(.cloudflareHostname)]
            ),
            SectionLayout(id: "cloudflareAuthentication", title: String(localized: "Authentication"), footer: nil, rows: authRows),
            SectionLayout(id: "cloudflareListener", title: String(localized: "Local Listener"), footer: nil, rows: listenerRows),
            SectionLayout(id: "cloudflareBinary", title: "cloudflared", footer: nil, rows: [.builtIn(.cloudflareBinary)])
        ]
    }

    private static func cloudSQLSections(_ draft: ConnectionDraft) -> [SectionLayout] {
        var authRows: [EditorRow] = [.builtIn(.cloudSQLAuthMode)]
        if draft.cloudSQLProxy.authMode == .serviceAccountKey {
            authRows.append(.builtIn(.cloudSQLServiceAccountKey))
        }
        authRows += [.builtIn(.cloudSQLIAMAuth), .builtIn(.cloudSQLPrivateIP)]
        var listenerRows: [EditorRow] = [.builtIn(.cloudSQLAutomaticPort)]
        if !draft.cloudSQLProxy.automaticPort {
            listenerRows.append(.builtIn(.cloudSQLLocalPort))
        }
        return [
            SectionLayout(
                id: "cloudSQLInstance",
                title: String(localized: "Cloud SQL Instance"),
                footer: nil,
                rows: [.builtIn(.cloudSQLInstance)]
            ),
            SectionLayout(id: "cloudSQLAuthentication", title: String(localized: "Authentication"), footer: nil, rows: authRows),
            SectionLayout(id: "cloudSQLListener", title: String(localized: "Local Listener"), footer: nil, rows: listenerRows),
            SectionLayout(id: "cloudSQLBinary", title: "cloud-sql-proxy", footer: nil, rows: [.builtIn(.cloudSQLBinary)])
        ]
    }

    private static func tunnelCommandSections(_ draft: ConnectionDraft) -> [SectionLayout] {
        var sections = [
            SectionLayout(id: "tunnelMethod", title: String(localized: "Method"), footer: nil, rows: [.builtIn(.tunnelCommandMethod)])
        ]
        switch draft.tunnelCommand.config.method {
        case .kubectl:
            sections.append(SectionLayout(
                id: "tunnelKubernetes",
                title: String(localized: "Kubernetes"),
                footer: nil,
                rows: [.builtIn(.kubernetesResource), .builtIn(.kubernetesNamespace), .builtIn(.kubernetesContext)]
            ))
            sections.append(executableSection())
        case .awsSSM:
            sections.append(SectionLayout(
                id: "tunnelAWS",
                title: String(localized: "AWS Systems Manager"),
                footer: nil,
                rows: [.builtIn(.awsTarget), .builtIn(.awsProfile), .builtIn(.awsRegion)]
            ))
            sections.append(executableSection())
        case .custom:
            sections.append(SectionLayout(
                id: "tunnelCustom",
                title: String(localized: "Command"),
                footer: nil,
                rows: [.builtIn(.tunnelCommand)]
            ))
        }
        sections.append(SectionLayout(
            id: "tunnelPreview",
            title: String(localized: "Will Run"),
            footer: nil,
            rows: [.builtIn(.tunnelCommandPreview)]
        ))
        return sections
    }

    private static func executableSection() -> SectionLayout {
        SectionLayout(
            id: "tunnelExecutable",
            title: nil,
            footer: String(localized: """
                Leave blank to find it on your PATH. Apps launched from the Dock do not inherit \
                your shell's PATH, so a tool installed somewhere unusual needs its full path here.
                """),
            rows: [.builtIn(.tunnelCommandExecutable)]
        )
    }

    // MARK: - SSL

    private static func sslFacet(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> FacetLayout {
        let mode = draft.ssl.mode
        var modeRows: [EditorRow] = [.builtIn(.sslMode)]
        if mode == .preferred, !traits.ssl.supportsOpportunisticTLS {
            modeRows.append(.builtIn(.sslNoFallbackNotice))
        }
        var footerLines: [String] = []
        if !traits.ssl.note.isEmpty {
            footerLines.append(traits.ssl.note)
        }
        if mode != .disabled {
            footerLines.append(mode.description)
        }
        if usesLocalSocket(draft, traits), mode == .preferred {
            footerLines.append(String(localized: "Preferred leaves a socket connection unencrypted. Required encrypts it."))
        }
        var sections = [
            SectionLayout(
                id: "sslMode",
                title: nil,
                footer: footerLines.isEmpty ? nil : footerLines.joined(separator: "\n"),
                rows: modeRows
            )
        ]
        guard mode != .disabled else {
            return FacetLayout(facet: .sslTLS, title: ConnectionFacet.sslTLS.title, sections: sections)
        }
        guard traits.ssl.supportsPerConnectionCertificatePaths else {
            sections.append(SectionLayout(
                id: "sslTrust",
                title: String(localized: "Certificate Trust"),
                footer: nil,
                rows: [.builtIn(.sslCertificateTrustNote)]
            ))
            return FacetLayout(facet: .sslTLS, title: ConnectionFacet.sslTLS.title, sections: sections)
        }
        if mode == .verifyCa || mode == .verifyIdentity {
            let optional = !traits.ssl.requiresCACertificate(for: mode)
            sections.append(SectionLayout(
                id: "sslCA",
                title: String(localized: "CA Certificate"),
                footer: optional ? String(localized: "Leave empty to use the system trust store.") : nil,
                rows: [.builtIn(.sslCACertificate)]
            ))
        }
        var clientRows: [EditorRow] = [.builtIn(.sslClientCertificate), .builtIn(.sslClientKey)]
        if traits.ssl.supportsClientKeyPassphrase, !draft.ssl.clientKeyPath.trimmingCharacters(in: .whitespaces).isEmpty {
            clientRows.append(.builtIn(.sslClientKeyPassphrase))
        }
        sections.append(SectionLayout(
            id: "sslClient",
            title: String(localized: "Client Certificates"),
            footer: String(localized: "Required only when the server enforces mutual TLS authentication."),
            rows: clientRows
        ))
        return FacetLayout(facet: .sslTLS, title: ConnectionFacet.sslTLS.title, sections: sections)
    }

    // MARK: - Appearance, Safe Mode, AI, Startup

    private static func appearanceFacet() -> FacetLayout {
        FacetLayout(facet: .appearance, title: ConnectionFacet.appearance.title, sections: [
            SectionLayout(
                id: "appearance",
                title: nil,
                footer: String(localized: "The icon and color mark this connection in the connection list and its window."),
                rows: [.builtIn(.icon), .builtIn(.color), .builtIn(.tags), .builtIn(.group)]
            )
        ])
    }

    private static func safeModeFacet(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits, _ context: EditorContext) -> FacetLayout {
        var footerLines: [String] = []
        if let floor = safeModeFloor(draft, traits, context) {
            footerLines.append(floor.explanation)
        }
        if traits.manualCommitAvailable {
            // swiftlint:disable:next line_length
            footerLines.append(String(localized: "Your first change opens a transaction, and nothing is saved until you commit. Structure changes, Users & Roles, Copy To, Generate Rows and Shortcuts actions still save at once."))
        } else {
            footerLines.append(ManualCommit.unavailableExplanation)
        }
        return FacetLayout(facet: .safeMode, title: ConnectionFacet.safeMode.title, sections: [
            SectionLayout(
                id: "safeMode",
                title: nil,
                footer: footerLines.joined(separator: "\n"),
                rows: [.builtIn(.safeModeLevel), .builtIn(.manualCommit)]
            ),
            SectionLayout(
                id: "masking",
                title: String(localized: "Masking"),
                footer: String(localized: """
                    Hides matching values in the grid, copies, exports, shared links, the AI assistant and MCP. \
                    A pattern is table.column or column, with * as a wildcard, such as *.email. \
                    Filters and sorts still run on the stored values, so masking does not replace database permissions.
                    """),
                rows: [.builtIn(.maskingRules)]
            )
        ])
    }

    private static func aiFacet(_ draft: ConnectionDraft, _ context: EditorContext) -> FacetLayout {
        var sections = [
            SectionLayout(id: "externalClients", title: String(localized: "External Clients"), footer: nil, rows: [.builtIn(.externalAccess)])
        ]
        // AI Policy also governs MCP clients, so it stays reachable while AI features are off.
        var aiRows: [EditorRow] = [.builtIn(.aiPolicy)]
        if context.aiEnabled, !draft.ai.alwaysAllowedTools.isEmpty {
            aiRows.append(.builtIn(.alwaysAllowedTools))
        }
        sections.append(SectionLayout(id: "ai", title: String(localized: "AI"), footer: nil, rows: aiRows))
        if context.aiEnabled {
            sections.append(SectionLayout(
                id: "aiRules",
                title: String(localized: "AI Rules"),
                // swiftlint:disable:next line_length
                footer: String(localized: "Guidance the AI sees on every chat turn for this connection: table conventions, columns to avoid, join hints, business rules the schema doesn't show."),
                rows: [.builtIn(.aiRules)]
            ))
        }
        return FacetLayout(facet: .aiAndMCP, title: ConnectionFacet.aiAndMCP.title, sections: sections)
    }

    private static func startupFacet() -> FacetLayout {
        FacetLayout(facet: .startup, title: ConnectionFacet.startup.title, sections: [
            SectionLayout(
                id: "startupCommands",
                title: String(localized: "Startup Commands"),
                footer: String(localized: "SQL commands to run after connecting, e.g. SET time_zone = 'Asia/Ho_Chi_Minh'. One per line or separated by semicolons."),
                rows: [.builtIn(.startupCommands)]
            ),
            SectionLayout(
                id: "preConnect",
                title: String(localized: "Pre-Connect Script"),
                footer: String(localized: """
                    Runs in bash before connecting. A non-zero exit aborts the connection. \
                    TABLEPRO_CONNECTION_NAME, TABLEPRO_HOST, TABLEPRO_PORT, TABLEPRO_USER and \
                    TABLEPRO_DATABASE describe the connection.
                    """),
                rows: [.builtIn(.preConnectScript), .builtIn(.scriptTimeout)]
            ),
            SectionLayout(
                id: "postDisconnect",
                title: String(localized: "Post-Disconnect Script"),
                footer: String(localized: "Runs in bash once the session ends, only after its pre-connect script ran. A failure is logged, not shown."),
                rows: [.builtIn(.postDisconnectScript)]
            )
        ])
    }

    // MARK: - Advanced

    private static func advancedFacet(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits, _ context: EditorContext) -> FacetLayout {
        let advancedFields = traits.fields.filter { $0.section == .advanced }
        var sections: [SectionLayout] = []
        let driverRows = pluginRows(advancedFields.filter { $0.content == .plain }, draft, traits)
        if !driverRows.isEmpty {
            sections.append(SectionLayout(id: "driver", title: traits.displayName, footer: nil, rows: driverRows))
        }
        for field in advancedFields where field.content == .attachedDatabases && isVisible(field, draft, traits) {
            sections.append(SectionLayout(
                id: "attachedDatabases-\(field.id)",
                title: field.label,
                footer: String(localized: "Attached each time the connection opens. Reach a table as name.table, and browse each database in the sidebar."),
                rows: [.plugin(fieldID: field.id)]
            ))
        }
        for field in advancedFields where field.content == .loadableExtensions && isVisible(field, draft, traits) {
            sections.append(SectionLayout(
                id: "extensions-\(field.id)",
                title: field.label,
                // swiftlint:disable:next line_length
                footer: String(localized: "Loaded in this order each time the database file opens on this Mac. An extension runs with full access to your Mac, so add only files you trust."),
                rows: [.plugin(fieldID: field.id)]
            ))
        }
        sections.append(SectionLayout(
            id: "timeouts",
            title: String(localized: "Timeouts"),
            footer: String(localized: """
                Query timeout applies only to database drivers that support it. \
                Use 0 for no limit. Reconnect to apply changes.
                """),
            rows: [.builtIn(.connectTimeout), .builtIn(.queryTimeout)]
        ))
        if traits.supportsBinaryInlineLimit {
            sections.append(SectionLayout(
                id: "tableData",
                title: String(localized: "Table Data"),
                footer: String(localized: """
                    A larger text, JSON or binary value stays on the server until you open, copy or export it. \
                    The grid shows the start of a text value. Applies to tables with a primary key.
                    """),
                rows: [.builtIn(.binaryInlineLimit)]
            ))
        }
        if traits.supportsIdentifierCase {
            sections.append(SectionLayout(
                id: "autocomplete",
                title: String(localized: "Autocomplete"),
                footer: String(localized: """
                    Table, column and schema names take this case in autocomplete and in Copy as INSERT \
                    and UPDATE when the server reads the new spelling as the same name. Other names are \
                    quoted as stored.
                    """),
                rows: [.builtIn(.identifierCase)]
            ))
        }
        if context.syncEnabled {
            sections.append(SectionLayout(
                id: "sync",
                title: String(localized: "iCloud Sync"),
                footer: String(localized: "This connection won't sync to other devices via iCloud."),
                rows: [.builtIn(.localOnly)]
            ))
        }
        return FacetLayout(facet: .advanced, title: ConnectionFacet.advanced.title, sections: sections)
    }
}
