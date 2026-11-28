//
//  SyncApprovalPresentationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProFFI
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
                ("/additional_fields/privateKeyPassphrase", nil, "\"hunter2\""),
                ("/additional_fields/warehouse", "\"small\"", "\"large\"")
            ]
        )
        let lookup = SyncApprovalLookup(
            profileName: { _, _ in nil },
            aiProviderName: { _ in nil },
            driverField: { _, _, id in
                id == "privateKeyPassphrase"
                    ? .init(label: "Key Passphrase", isSecure: true)
                    : .init(label: "Warehouse", isSecure: false)
            }
        )

        let item = SyncApprovalPresentation.item(record, lookup: lookup)

        let secret = try #require(Self.row(item, "/additional_fields/privateKeyPassphrase"))
        #expect(secret.label == "Key Passphrase")
        #expect(secret.from == .hidden)
        #expect(secret.to == .hidden)
        #expect(!SyncApprovalPresentation.spoken(secret).contains("hunter2"))
        #expect(Self.row(item, "/additional_fields/warehouse")?.to == .text("large"))
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
            driverField: { _, _, _ in nil }
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
