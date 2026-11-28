//
//  SyncApprovalPresentationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProFFI
import TableProPluginKit
import Testing

@MainActor
struct SyncApprovalPresentationTests {
    private static func row(_ item: SyncApprovalItem, _ field: String) -> SyncApprovalItem.Row? {
        item.rows.first { $0.id == field }
    }

    @Test("A new connection shows only the pulled values that set something, destination first")
    func newConnection() {
        let item = SyncApprovalPresentation.item(SyncApprovalFixture.newConnection(), lookup: .none)

        #expect(item.title == "Orders Production")
        #expect(item.subtitle == String(localized: "New connection"))
        #expect(item.isNew)
        #expect(!item.isTeam)
        #expect(item.rows.map(\.id) == ["/type", "/host", "/port", "/database", "/username", "/ssl_config/mode"])
        #expect(item.rows.allSatisfy { $0.from == nil })
        #expect(Self.row(item, "/host")?.label == String(localized: "Host"))
        #expect(Self.row(item, "/host")?.to == .text("db.example.com"))
        #expect(Self.row(item, "/port")?.to == .text("5432"))
        #expect(Self.row(item, "/ssl_config/mode")?.label == String(localized: "SSL Mode"))
    }

    @Test("A changed connection shows this Mac's value and the pulled one, in the form's words")
    func changedConnection() {
        let item = SyncApprovalPresentation.item(SyncApprovalFixture.changedConnection(), lookup: .none)

        #expect(item.subtitle == String(localized: "Changed connection"))
        #expect(!item.isNew)
        let host = Self.row(item, "/host")
        #expect(host?.from == .text("analytics.internal"))
        #expect(host?.to == .text("analytics.example.net"))
        let safeMode = Self.row(item, "/safe_mode_level")
        #expect(safeMode?.label == String(localized: "Safe Mode"))
        #expect(safeMode?.from == .text(SafeModeLevel.readOnly.displayName))
        #expect(safeMode?.to == .text(SafeModeLevel.silent.displayName))
        let startup = Self.row(item, "/startup_commands")
        #expect(startup?.from == .notSet)
        #expect(startup?.to == .code("SET search_path TO reporting;\nSET statement_timeout = 0;"))
    }

    @Test("Team Library values read with the personal kinds' labels, and the record sits under Team Library")
    func teamRecord() {
        let record = SyncApprovalFixture.approval(
            SyncApprovalFixture.record("lib-1", kind: "library_connection", scope: SyncApprovalFixture.team),
            name: "Shared Warehouse",
            isNew: false,
            fields: [
                ("/sshConfig/host", "\"bastion-a.example.com\"", "\"bastion-b.example.com\""),
                ("/sslConfig/caCertificatePath", nil, "\"/etc/ssl/ca.pem\""),
                ("/aiPolicy", "\"never\"", "\"alwaysAllow\"")
            ]
        )

        let item = SyncApprovalPresentation.item(record, lookup: .none)

        #expect(item.isTeam)
        #expect(item.subtitle == String(localized: "Changed Team Library connection"))
        #expect(Self.row(item, "/sshConfig/host")?.label == String(localized: "SSH Host"))
        #expect(Self.row(item, "/sslConfig/caCertificatePath")?.label == String(localized: "CA Certificate"))
        #expect(Self.row(item, "/aiPolicy")?.to == .text(AIConnectionPolicy.alwaysAllow.displayName))
    }

    @Test("A driver field the Mac knows as secure never shows its value")
    func secureDriverFieldHidden() throws {
        let record = SyncApprovalFixture.approval(
            SyncApprovalFixture.record(SyncApprovalFixture.changedID),
            name: "Snowflake",
            isNew: false,
            fields: [
                ("/additional_fields/privateKeyPassphrase", nil, #"{"id":"privateKeyPassphrase","value":"hunter2"}"#),
                ("/additional_fields/warehouse", #"{"id":"warehouse","value":"small"}"#, #"{"id":"warehouse","value":"large"}"#)
            ]
        )
        var traits = ConnectionTypeTraits(type: DatabaseType(rawValue: "Snowflake"))
        traits.fields = [
            ConnectionField(id: "privateKeyPassphrase", label: "Key Passphrase", fieldType: .secure),
            ConnectionField(id: "warehouse", label: "Warehouse")
        ]
        let item = SyncApprovalPresentation.item(record, lookup: Self.lookup(traits, local: .init(type: "Snowflake")))

        let secret = try #require(Self.row(item, "/additional_fields/privateKeyPassphrase"))
        #expect(secret.label == "Key Passphrase")
        #expect(secret.from == .hidden)
        #expect(secret.to == .hidden)
        #expect(!SyncApprovalPresentation.spoken(secret).contains("hunter2"))
        #expect(Self.row(item, "/additional_fields/warehouse")?.to == .text("large"))
    }

    // MARK: - Driver fields and the rows a driver shows

    private static func lookup(_ traits: ConnectionTypeTraits, local: SyncApprovalConnectionState? = nil) -> SyncApprovalLookup {
        SyncApprovalLookup(
            profileName: { _, _ in nil },
            aiProviderName: { _ in nil },
            traits: { type in type == traits.type.rawValue ? traits : nil },
            connection: { _ in local }
        )
    }

    // Postgres as its plugin declares it: the Authentication picker with Kerberos, GSS Encryption under Kerberos only,
    // and the ~/.pgpass switch.
    private static var postgres: ConnectionTypeTraits {
        var traits = ConnectionTypeTraits(type: DatabaseType(rawValue: "PostgreSQL"))
        traits.connectionMode = .network
        traits.defaultPort = 5_432
        traits.fields = KerberosAuthFields.standardWithAWS() + [
            KerberosAuthFields.gssEncryptionField(),
            ConnectionField(
                id: "usePgpass",
                label: "Use ~/.pgpass",
                defaultValue: "false",
                fieldType: .toggle,
                section: .authentication,
                hidesPassword: true
            )
        ]
        return traits
    }

    // SQLite: a file, with no sign-in, SSH tunnel or TLS.
    private static var sqlite: ConnectionTypeTraits {
        var traits = ConnectionTypeTraits(type: DatabaseType(rawValue: "SQLite"))
        traits.connectionMode = .fileBased
        traits.localFilePathField = .database
        traits.supportsSSH = false
        traits.supportsSSL = false
        return traits
    }

    private static func entry(_ id: String, _ value: String) -> String {
        #"{"id":"\#(id)","value":"\#(value)"}"#
    }

    @Test("A new Postgres connection reads its driver fields as the form does, with one row per label")
    func newPostgres() {
        let record = SyncApprovalFixture.approval(
            SyncApprovalFixture.record(SyncApprovalFixture.newID),
            name: "e2e-pg",
            isNew: true,
            fields: [
                ("/type", nil, "\"PostgreSQL\""),
                ("/host", nil, "\"db.example.com\""),
                ("/port", nil, "5432"),
                ("/database", nil, "\"orders\""),
                ("/username", nil, "\"app\""),
                ("/auth_mode", nil, "\"password\""),
                ("/ssh_config/enabled", nil, "false"),
                ("/ssh_config/auth_method", nil, "\"Password\""),
                ("/ssl_config/mode", nil, "\"Preferred\""),
                ("/additional_fields/awsAuth", nil, Self.entry("awsAuth", "off")),
                ("/additional_fields/usePgpass", nil, Self.entry("usePgpass", "false")),
                ("/additional_fields/gssEncryptionMode", nil, Self.entry("gssEncryptionMode", "prefer"))
            ]
        )

        let item = SyncApprovalPresentation.item(record, lookup: Self.lookup(Self.postgres))

        #expect(item.rows.map(\.id) == [
            "/type", "/host", "/port", "/database", "/username", "/additional_fields/awsAuth", "/ssl_config/mode"
        ])
        #expect(Self.row(item, "/additional_fields/awsAuth")?.label == String(localized: "Authentication"))
        #expect(Self.row(item, "/additional_fields/awsAuth")?.to == .text(String(localized: "Password")))
        #expect(Set(item.rows.map(\.label)).count == item.rows.count)
        for row in item.rows {
            #expect(!SyncApprovalPresentation.spoken(row).contains("{"), "\(row.id)")
        }
    }

    @Test("Kerberos picked shows GSS Encryption by its option's label, unset at its default, and ~/.pgpass on reads On")
    func postgresKerberos() {
        let record = SyncApprovalFixture.approval(
            SyncApprovalFixture.record(SyncApprovalFixture.changedID),
            name: "e2e-pg",
            isNew: false,
            fields: [
                ("/additional_fields/awsAuth", Self.entry("awsAuth", "off"), Self.entry("awsAuth", "kerberos")),
                ("/additional_fields/gssEncryptionMode", nil, Self.entry("gssEncryptionMode", "require")),
                ("/additional_fields/usePgpass", Self.entry("usePgpass", "false"), Self.entry("usePgpass", "true"))
            ]
        )
        let local = SyncApprovalConnectionState(type: "PostgreSQL", sshEnabled: false, sslMode: "Disabled")

        let item = SyncApprovalPresentation.item(record, lookup: Self.lookup(Self.postgres, local: local))

        #expect(Self.row(item, "/additional_fields/awsAuth")?.from == .text(String(localized: "Password")))
        #expect(Self.row(item, "/additional_fields/awsAuth")?.to == .text(String(localized: "Kerberos (GSSAPI)")))
        #expect(Self.row(item, "/additional_fields/gssEncryptionMode")?.label == String(localized: "GSS Encryption"))
        #expect(Self.row(item, "/additional_fields/gssEncryptionMode")?.from == .text(String(localized: "Preferred")))
        #expect(Self.row(item, "/additional_fields/gssEncryptionMode")?.to == .text(String(localized: "Required")))
        #expect(Self.row(item, "/additional_fields/usePgpass")?.from == .text(String(localized: "Off")))
        #expect(Self.row(item, "/additional_fields/usePgpass")?.to == .text(String(localized: "On")))
    }

    @Test("A new SQLite connection shows its file, never a host, port, sign-in, SSH or TLS row")
    func newSQLite() {
        let record = SyncApprovalFixture.approval(
            SyncApprovalFixture.record(SyncApprovalFixture.newID),
            name: "e2e-sqlite",
            isNew: true,
            fields: [
                ("/type", nil, "\"SQLite\""),
                ("/host", nil, "\"localhost\""),
                ("/port", nil, "0"),
                ("/database", nil, "\"~/Data/app.sqlite\""),
                ("/auth_mode", nil, "\"password\""),
                ("/ssh_config/enabled", nil, "false"),
                ("/ssh_config/auth_method", nil, "\"Password\""),
                ("/ssl_config/mode", nil, "\"Disabled\""),
                ("/safe_mode_level", nil, "\"silent\"")
            ]
        )

        let item = SyncApprovalPresentation.item(record, lookup: Self.lookup(Self.sqlite))

        #expect(item.rows.map(\.id) == ["/type", "/database", "/safe_mode_level"])
        #expect(Self.row(item, "/database")?.label == String(localized: "File Path"))
        #expect(Self.row(item, "/database")?.to == .text("~/Data/app.sqlite"))
    }

    @Test("SSH rows follow the tunnel and its sign-in: none while it stays off, only the method's own once on")
    func sshRowsFollowTheTunnel() {
        let changes: [(String, String?, String?)] = [
            ("/ssh_config/host", "\"bastion-a.example.com\"", "\"bastion-b.example.com\""),
            ("/ssh_config/private_key_path", "\"~/.ssh/a\"", "\"~/.ssh/b\""),
            ("/ssh_config/agent_socket_path", nil, "\"/tmp/agent.sock\"")
        ]
        let on = SyncApprovalConnectionState(type: "PostgreSQL", sshEnabled: true, sshAuthMethod: "Private Key")
        let record = SyncApprovalFixture.approval(
            SyncApprovalFixture.record(SyncApprovalFixture.changedID), name: "Billing", isNew: false, fields: changes
        )
        let tunnelOn = SyncApprovalPresentation.item(record, lookup: Self.lookup(Self.postgres, local: on))
        #expect(tunnelOn.rows.map(\.id) == ["/ssh_config/host", "/ssh_config/private_key_path"])

        let turnedOff = SyncApprovalFixture.approval(
            SyncApprovalFixture.record(SyncApprovalFixture.changedID),
            name: "Billing",
            isNew: false,
            fields: changes + [("/ssh_config/enabled", "true", "false")]
        )
        let tunnelOff = SyncApprovalPresentation.item(turnedOff, lookup: Self.lookup(Self.postgres, local: on))
        #expect(tunnelOff.rows.map(\.id) == ["/ssh_config/enabled"])
        #expect(tunnelOff.rows.first?.to == .text(String(localized: "Off")))
    }

    @Test("A setting this Mac cannot read keeps the fields it controls in sight")
    func unknownControllerValueShows() {
        var traits = ConnectionTypeTraits(type: DatabaseType(rawValue: "libSQL"))
        traits.fields = [
            ConnectionField(
                id: "libsqlMode",
                label: "Mode",
                defaultValue: "local",
                fieldType: .dropdown(options: [.init(value: "local", label: "Local"), .init(value: "remote", label: "Remote")]),
                section: .connection
            ),
            ConnectionField(
                id: "databaseUrl",
                label: "Database URL",
                section: .connection,
                visibleWhen: FieldVisibilityRule(fieldId: "libsqlMode", values: ["remote"])
            )
        ]
        let record = SyncApprovalFixture.approval(
            SyncApprovalFixture.record(SyncApprovalFixture.changedID),
            name: "Edge",
            isNew: false,
            fields: [
                ("/additional_fields/libsqlMode", Self.entry("libsqlMode", "local"), Self.entry("libsqlMode", "future")),
                ("/additional_fields/databaseUrl", nil, Self.entry("databaseUrl", "libsql://evil.example.com"))
            ]
        )

        let item = SyncApprovalPresentation.item(record, lookup: Self.lookup(traits, local: .init(type: "libSQL")))

        #expect(Self.row(item, "/additional_fields/databaseUrl")?.to == .text("libsql://evil.example.com"))
        #expect(Self.row(item, "/additional_fields/libsqlMode")?.to == .text("future"))
    }

    @Test("A credential profile or password source change shows for every driver, file and API ones included")
    func credentialsShowForEveryDriver() {
        var api = ConnectionTypeTraits(type: DatabaseType(rawValue: "CloudAPI"))
        api.connectionMode = .apiOnly
        let fields: [(String, String?, String?)] = [
            ("/credential_profile_id", nil, SyncApprovalFixture.json("AAAAAAAA-0000-4000-8000-000000000000")),
            ("/credential_reference/kind", nil, "\"env\"")
        ]
        let record = SyncApprovalFixture.approval(
            SyncApprovalFixture.record(SyncApprovalFixture.changedID), name: "API", isNew: false, fields: fields
        )
        let file = SyncApprovalFixture.approval(
            SyncApprovalFixture.record(SyncApprovalFixture.changedID), name: "File", isNew: false, fields: fields
        )

        let apiItem = SyncApprovalPresentation.item(record, lookup: Self.lookup(api, local: .init(type: "CloudAPI")))
        let fileItem = SyncApprovalPresentation.item(file, lookup: Self.lookup(Self.sqlite, local: .init(type: "SQLite")))

        #expect(apiItem.rows.map(\.id) == ["/credential_profile_id", "/credential_reference/kind"])
        #expect(fileItem.rows.map(\.id) == ["/credential_profile_id", "/credential_reference/kind"])
    }

    @Test("Under the SSH agent the identity file shows, and each spelling of a method reads the same")
    func sshAgentIdentityShows() {
        let changes: [(String, String?, String?)] = [
            ("/ssh_config/private_key_path", "\"~/.ssh/a\"", "\"~/.ssh/b\""),
            ("/ssh_config/agent_socket_path", nil, "\"/tmp/agent.sock\"")
        ]
        let record = SyncApprovalFixture.approval(
            SyncApprovalFixture.record(SyncApprovalFixture.changedID), name: "Billing", isNew: false, fields: changes
        )
        for spelling in ["SSH Agent", "sshAgent"] {
            let local = SyncApprovalConnectionState(type: "PostgreSQL", sshEnabled: true, sshAuthMethod: spelling)
            let item = SyncApprovalPresentation.item(record, lookup: Self.lookup(Self.postgres, local: local))
            #expect(item.rows.map(\.id) == ["/ssh_config/private_key_path", "/ssh_config/agent_socket_path"], "\(spelling)")
        }
        let legacyKey = SyncApprovalConnectionState(type: "PostgreSQL", sshEnabled: true, sshAuthMethod: "privateKey")
        let keyItem = SyncApprovalPresentation.item(record, lookup: Self.lookup(Self.postgres, local: legacyKey))
        #expect(keyItem.rows.map(\.id) == ["/ssh_config/private_key_path"])
    }

    @Test("A linked SSH profile this Mac does not hold leaves the connection's own server and sign-in in sight")
    func unresolvedProfileKeepsInlineSSH() {
        let profileID = "5F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9"
        let record = SyncApprovalFixture.approval(
            SyncApprovalFixture.record(SyncApprovalFixture.newID),
            name: "Billing",
            isNew: true,
            fields: [
                ("/type", nil, "\"PostgreSQL\""),
                ("/ssh_config/enabled", nil, "true"),
                ("/ssh_profile_id", nil, SyncApprovalFixture.json(profileID)),
                ("/ssh_config/host", nil, "\"bastion.example.com\""),
                ("/ssh_config/username", nil, "\"deploy\"")
            ]
        )
        var lookup = Self.lookup(Self.postgres)

        let unresolved = SyncApprovalPresentation.item(record, lookup: lookup)
        #expect(Self.row(unresolved, "/ssh_config/host") != nil)
        #expect(Self.row(unresolved, "/ssh_config/username") != nil)

        lookup.profileName = { kind, id in kind == "ssh_profile" && id == profileID ? "Bastion" : nil }
        let resolved = SyncApprovalPresentation.item(record, lookup: lookup)
        #expect(Self.row(resolved, "/ssh_config/host") == nil)
        #expect(Self.row(resolved, "/ssh_profile_id")?.to == .text("Bastion"))
    }

    @Test("Two rows that would read alike each name their member, so no label repeats")
    func repeatedLabelsNameTheirMember() {
        var traits = Self.postgres
        traits.fields.append(ConnectionField(id: "hostAlias", label: String(localized: "Host"), section: .connection))
        let record = SyncApprovalFixture.approval(
            SyncApprovalFixture.record(SyncApprovalFixture.changedID),
            name: "Billing",
            isNew: false,
            fields: [
                ("/host", "\"a.example.com\"", "\"b.example.com\""),
                ("/additional_fields/hostAlias", Self.entry("hostAlias", "a"), Self.entry("hostAlias", "b"))
            ]
        )

        let item = SyncApprovalPresentation.item(record, lookup: Self.lookup(traits, local: .init(type: "PostgreSQL")))

        #expect(item.rows.map(\.label) == [
            String(format: String(localized: "%1$@ (%2$@)"), String(localized: "Host"), "host"),
            String(format: String(localized: "%1$@ (%2$@)"), String(localized: "Host"), "hostAlias")
        ])
    }

    @Test("A driver this Mac does not know shows every value, each driver field by its value, never its JSON")
    func unknownDriverShowsEverything() {
        let record = SyncApprovalFixture.approval(
            SyncApprovalFixture.record(SyncApprovalFixture.newID),
            name: "Newer Engine",
            isNew: true,
            fields: [
                ("/type", nil, "\"FutureDB\""),
                ("/host", nil, "\"future.example.com\""),
                ("/auth_mode", nil, "\"password\""),
                ("/additional_fields/region", nil, Self.entry("region", "eu-west-1"))
            ]
        )

        let item = SyncApprovalPresentation.item(record, lookup: Self.lookup(Self.postgres))

        #expect(item.rows.map(\.id) == ["/type", "/host", "/auth_mode", "/additional_fields/region"])
        #expect(Self.row(item, "/additional_fields/region")?.label == "region")
        #expect(Self.row(item, "/additional_fields/region")?.to == .text("eu-west-1"))
    }

    @Test("A profile id reads as the profile's name, from this Mac or from a profile waiting beside it")
    func profileNames() {
        let profileID = "5F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9"
        let pendingID = "0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9"
        let connection = SyncApprovalFixture.approval(
            SyncApprovalFixture.record(SyncApprovalFixture.changedID),
            name: "Billing",
            isNew: false,
            fields: [
                ("/ssh_profile_id", SyncApprovalFixture.json(profileID), SyncApprovalFixture.json(pendingID)),
                ("/credential_profile_id", nil, SyncApprovalFixture.json("AAAAAAAA-0000-4000-8000-000000000000"))
            ]
        )
        let profile = SyncApprovalFixture.approval(
            SyncApprovalFixture.record(pendingID, kind: "ssh_profile"),
            name: "Bastion EU",
            isNew: true,
            fields: [("/host", nil, "\"bastion.eu.example.com\"")]
        )
        let lookup = SyncApprovalLookup(
            profileName: { kind, id in kind == "ssh_profile" && id == profileID ? "Bastion US" : nil },
            aiProviderName: { _ in nil },
            traits: { _ in nil },
            connection: { _ in nil }
        )

        let items = SyncApprovalPresentation.items([connection, profile], lookup: lookup)

        let link = Self.row(items[0], "/ssh_profile_id")
        #expect(link?.from == .text("Bastion US"))
        #expect(link?.to == .text("Bastion EU"))
        #expect(Self.row(items[0], "/credential_profile_id")?.to == .text(String(localized: "A profile not on this Mac")))
        #expect(items[1].subtitle == String(localized: "New SSH profile"))
    }

    @Test("AI settings read with the Settings pane's words, and a provider by its name and endpoint")
    func aiSettings() {
        let record = SyncApprovalFixture.approval(
            SyncApprovalFixture.record("ai", kind: "macos_settings"),
            name: "ai",
            isNew: false,
            fields: [
                ("/options/includeQueryResults", "false", "true"),
                ("/options/maxSchemaTables", "20", "500"),
                ("/options/providers", "[]", #"[{"id":"p1","type":"openAI","name":"","endpoint":"https://llm.example.com/v1"}]"#)
            ]
        )

        let item = SyncApprovalPresentation.item(record, lookup: .none)

        #expect(item.title == SettingsPane.ai.title)
        #expect(item.subtitle == String(localized: "Changed settings"))
        #expect(Self.row(item, "/options/includeQueryResults")?.label == String(localized: "Include query results"))
        #expect(Self.row(item, "/options/includeQueryResults")?.to == .text(String(localized: "On")))
        #expect(Self.row(item, "/options/maxSchemaTables")?.to == .text("500"))
        #expect(Self.row(item, "/options/providers")?.from == .text(String(localized: "None")))
        guard case .lines(let lines)? = Self.row(item, "/options/providers")?.to else {
            Issue.record("A provider list reads one line per provider")
            return
        }
        #expect(lines.count == 1)
        #expect(lines[0].contains("OpenAI"))
        #expect(lines[0].contains("https://llm.example.com/v1"))
    }

    @Test("A change to any member of a list item shows, since the core applies the list whole")
    func listMembersAllShow() {
        let jump = #"[{"id":"j1","host":"bastion.example.com","port":22,"username":"app","auth_method":"%@","private_key_path":"%@"}]"#
        let provider = #"[{"id":"p1","type":"openAI","name":"Work","endpoint":"https://llm.example.com/v1","telemetryEnabled":%@}]"#
        let record = SyncApprovalFixture.approval(
            SyncApprovalFixture.record(SyncApprovalFixture.changedID),
            name: "Billing",
            isNew: false,
            fields: [(
                "/ssh_config/jump_hosts",
                String(format: jump, "SSH Agent", ""),
                String(format: jump, "Private Key", "~/.ssh/other")
            )]
        )
        let settings = SyncApprovalFixture.approval(
            SyncApprovalFixture.record("ai", kind: "macos_settings"),
            name: "ai",
            isNew: false,
            fields: [("/options/providers", String(format: provider, "false"), String(format: provider, "true"))]
        )

        let jumps = Self.row(SyncApprovalPresentation.item(record, lookup: .none), "/ssh_config/jump_hosts")
        let providers = Self.row(SyncApprovalPresentation.item(settings, lookup: .none), "/options/providers")

        #expect(jumps?.from != jumps?.to)
        guard case .lines(let pulled)? = jumps?.to else {
            Issue.record("Jump hosts read one line per host")
            return
        }
        #expect(pulled[0].contains("~/.ssh/other"))
        #expect(pulled[0].contains(String(localized: "Private Key")))
        #expect(!pulled[0].contains("j1"))
        #expect(providers?.from != providers?.to)
    }

    @Test("A key the Mac has no words for shows its hidden characters, in the label as in VoiceOver")
    func hostileLabelsVisible() {
        let record = SyncApprovalFixture.approval(
            SyncApprovalFixture.record(SyncApprovalFixture.changedID),
            name: "Billing",
            isNew: false,
            fields: [("/additional_fields/host\u{202E}tsoh", "\"a\"", "\"b\"")]
        )

        let row = SyncApprovalPresentation.item(record, lookup: .none).rows.first

        #expect(row?.label == "host<U+202E>tsoh")
        #expect(row.map { SyncApprovalPresentation.spoken($0) }?.contains("\u{202E}") == false)
    }

    @Test("A value that would reorder or hide text shows each control as a code point")
    func trojanSourceVisible() {
        let record = SyncApprovalFixture.approval(
            SyncApprovalFixture.record(SyncApprovalFixture.changedID),
            name: "Prod\u{202E}gnp.exe",
            isNew: false,
            fields: [("/host", "\"a.example.com\"", SyncApprovalFixture.json("evil.example.com\u{202E}moc.elpmaxe"))]
        )

        let item = SyncApprovalPresentation.item(record, lookup: .none)

        #expect(item.title == "Prod<U+202E>gnp.exe")
        #expect(Self.row(item, "/host")?.to == .text("evil.example.com<U+202E>moc.elpmaxe"))
    }

    @Test("VoiceOver reads a field's label with the change, and only the value for a new record")
    func spokenRows() {
        let changed = SyncApprovalItem.Row(id: "/host", label: "Host", from: .text("a"), to: .text("b"))
        let new = SyncApprovalItem.Row(id: "/host", label: "Host", from: nil, to: .text("b"))

        #expect(SyncApprovalPresentation.spoken(changed) == String(format: String(localized: "%1$@, from %2$@ to %3$@"), "Host", "a", "b"))
        #expect(SyncApprovalPresentation.spoken(new) == String(format: String(localized: "%1$@: %2$@"), "Host", "b"))
    }

    @Test("The count reads as one change or many")
    func waitingLine() {
        #expect(SyncApprovalPresentation.waitingLine(1) == String(localized: "1 change needs your approval"))
        #expect(SyncApprovalPresentation.waitingLine(3) == String(format: String(localized: "%lld changes need your approval"), Int64(3)))
    }
}
