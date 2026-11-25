//
//  ConnectionRecordInvariantsTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import TableProSSHConfig
import Testing

@testable import TablePro

// Each case builds the record Save's merge produces when another writer changed the stored one after the editor
// loaded it, checks the merge broke the rule, then that enforce restores it. record-invariants.md lists the rules.
@MainActor
struct ConnectionRecordInvariantsTests {
    private static let probe = DatabaseType(rawValue: "InvariantProbe")
    private static let otherProbe = DatabaseType(rawValue: "InvariantProbeOther")

    private func probeTraits(
        _ type: DatabaseType = probe,
        _ configure: (inout ConnectionTypeTraits) -> Void = { _ in }
    ) -> ConnectionTypeTraits {
        var traits = ConnectionTypeTraits(type: type)
        traits.defaultPort = 5_000
        configure(&traits)
        return traits
    }

    private func stored(_ traits: ConnectionTypeTraits) -> DatabaseConnection {
        DatabaseConnection(name: "Orders", host: "db.example.com", port: 5_000, username: "app", type: traits.type)
    }

    private func merged(
        stored: DatabaseConnection,
        fresh: DatabaseConnection,
        traits: ConnectionTypeTraits,
        originalTraits: ConnectionTypeTraits? = nil,
        context: EditorContext = EditorContext(),
        edit: (inout ConnectionDraft) -> Void
    ) -> DatabaseConnection {
        let loadedTraits = originalTraits ?? traits
        let baseline = ConnectionDraft.loaded(from: stored, secrets: .none, traits: loadedTraits)
        var draft = baseline
        edit(&draft)
        let since = ConnectionEditorEngine.edits(baseline, loadedTraits, originalTraits: loadedTraits, context)
        return ConnectionEditorEngine.edits(draft, traits, originalTraits: loadedTraits, context)
            .applied(to: fresh, since: since)
    }

    private func enforce(
        _ record: DatabaseConnection,
        _ traits: ConnectionTypeTraits,
        originalTraits: ConnectionTypeTraits? = nil,
        context: EditorContext = EditorContext(),
        use: ConnectionRecordInvariants.Use = .save
    ) -> ConnectionRecordInvariants.Outcome {
        ConnectionRecordInvariants.enforce(
            record, traits: traits, originalTraits: originalTraits ?? traits, context: context, use: use
        )
    }

    private func sshTunnel(remoteFilePath: String = "") -> SSHConfiguration {
        var config = SSHConfiguration(enabled: true, host: "bastion.example.com")
        config.remoteFilePath = remoteFilePath
        return config
    }

    // MARK: - Secrets

    @Test("A plain-text secure value the stored record still holds leaves it and is handed back for the Keychain")
    func plaintextSecureValueLeavesTheRecord() {
        let traits = probeTraits {
            $0.fields = [ConnectionField(id: "apiToken", label: "API Token", secure: true, section: .authentication)]
        }
        var record = stored(traits)
        record.additionalFields["apiToken"] = "plain-old"

        let result = merged(stored: record, fresh: record, traits: traits) { $0.name = "Renamed" }
        #expect(result.additionalFields["apiToken"] == "plain-old")

        let outcome = enforce(result, traits)
        #expect(outcome.record.additionalFields["apiToken"] == nil)
        #expect(outcome.plaintextSecrets == ["apiToken": "plain-old"])
        #expect(outcome.record.name == "Renamed")
    }

    @Test("A plain-text secure value of the type the connection left leaves the retyped record")
    func plaintextSecureValueOfTheOldTypeLeaves() {
        let left = probeTraits {
            $0.fields = [ConnectionField(id: "legacyKey", label: "Key", secure: true, section: .authentication)]
        }
        let target = probeTraits(Self.otherProbe)
        let record = stored(left)
        var fresh = record
        fresh.additionalFields["legacyKey"] = "plain-elsewhere"

        let result = merged(stored: record, fresh: fresh, traits: target, originalTraits: left) {
            $0.retype(to: target, from: left)
        }
        #expect(result.type == target.type)
        #expect(result.additionalFields["legacyKey"] == "plain-elsewhere")

        let outcome = enforce(result, target, originalTraits: left)
        #expect(outcome.record.additionalFields["legacyKey"] == nil)
        #expect(outcome.plaintextSecrets == ["legacyKey": "plain-elsewhere"])
    }

    // MARK: - Retype

    @Test("A retyped record keeps no field only the type it left declares, even one set elsewhere after load")
    func fieldOfTheOldTypeLeaves() {
        let left = probeTraits { $0.fields = [ConnectionField(id: "region", label: "Region", section: .connection)] }
        let target = probeTraits(Self.otherProbe)
        let record = stored(left)
        var fresh = record
        fresh.additionalFields["region"] = "eu-west-1"
        fresh.additionalFields["undeclaredOption"] = "kept"

        let result = merged(stored: record, fresh: fresh, traits: target, originalTraits: left) {
            $0.retype(to: target, from: left)
        }
        #expect(result.additionalFields["region"] == "eu-west-1")

        let outcome = enforce(result, target, originalTraits: left)
        #expect(outcome.record.additionalFields["region"] == nil)
        #expect(outcome.record.additionalFields["undeclaredOption"] == "kept")
    }

    // MARK: - Transports

    @Test("Of two switched-on transports only the first, the one the editor loads, stays")
    func oneTransportStays() {
        let traits = probeTraits()
        var record = stored(traits)
        record.sshConfig = sshTunnel()
        record.sshTunnelMode = .inline(sshTunnel())
        record.socksProxyMode = .inline(SOCKSProxyConfiguration(host: "proxy.example.com", port: 1_080, username: ""))
        #expect(record.switchedOnTransports == [.ssh, .socksProxy])

        let outcome = enforce(record, traits)
        #expect(outcome.record.switchedOnTransports == [.ssh])
    }

    @Test("A transport another writer turned on that this type cannot dial is turned off")
    func transportTheTypeDoesNotOfferIsOff() {
        let traits = probeTraits { $0.supportsCloudflareTunnel = false }
        let record = stored(traits)
        var fresh = record
        fresh.cloudflareTunnelMode = .inline(CloudflareConfiguration(
            accessHostname: "db.example.com", localPort: nil, authMethod: .browserSSO, exposeToLAN: false, binaryPath: ""
        ))

        let result = merged(stored: record, fresh: fresh, traits: traits) { $0.name = "Renamed" }
        #expect(result.switchedOnTransports == [.cloudflare])

        let outcome = enforce(result, traits)
        #expect(outcome.record.cloudflareTunnelMode == .disabled)
        #expect(outcome.record.switchedOnTransports.isEmpty)
    }

    @Test("A transport stays where the type's host field shows, and goes where its mode hides it")
    func transportFollowsTheDialedEndpoint() {
        let traits = probeTraits {
            $0.connectionMode = .fileBased
            $0.fields = [
                ConnectionField(
                    id: "mode",
                    label: "Mode",
                    defaultValue: "local",
                    fieldType: .dropdown(options: [.init(value: "local", label: "Local"), .init(value: "remote", label: "Remote")]),
                    section: .connection
                ),
                ConnectionField(
                    id: "remoteHost",
                    label: "Host",
                    section: .connection,
                    visibleWhen: FieldVisibilityRule(fieldId: "mode", values: ["remote"])
                )
            ]
            $0.serverEndpointFields = ServerEndpointFields(hostFieldId: "remoteHost", portFieldId: "remotePort")
        }
        var record = stored(traits)
        record.additionalFields["mode"] = "remote"
        var fresh = record
        fresh.socksProxyMode = .inline(SOCKSProxyConfiguration(host: "proxy.example.com", port: 1_080, username: ""))
        #expect(enforce(fresh, traits).record.switchedOnTransports == [.socksProxy])

        let result = merged(stored: record, fresh: fresh, traits: traits) { $0.setFieldValue("local", for: "mode") }
        #expect(result.additionalFields["mode"] == "local")
        #expect(result.switchedOnTransports == [.socksProxy])

        let outcome = enforce(result, traits)
        #expect(outcome.record.switchedOnTransports.isEmpty)
    }

    @Test("The SSH profile id and configuration follow the tunnel mode")
    func sshLinkFollowsTheTunnelMode() {
        let traits = probeTraits()
        let record = stored(traits)
        var fresh = record
        fresh.sshProfileId = UUID()
        fresh.sshConfig = sshTunnel()

        let result = merged(stored: record, fresh: fresh, traits: traits) { $0.name = "Renamed" }
        #expect(result.sshTunnelMode == .disabled)
        #expect(result.sshProfileId != nil)

        let outcome = enforce(result, traits)
        #expect(outcome.record.sshProfileId == nil)
        #expect(!outcome.record.sshConfig.enabled)

        let profileId = UUID()
        var linked = result
        linked.sshTunnelMode = .profile(id: profileId, snapshot: sshTunnel())
        linked.sshProfileId = nil
        let relinked = enforce(linked, traits).record
        #expect(relinked.sshProfileId == profileId)
        #expect(relinked.sshConfig == sshTunnel())
    }

    @Test("A socket path to forward to stays only with an SSH port forward")
    func forwardSocketPathNeedsSSH() {
        let traits = probeTraits()
        let key = DatabaseConnection.sshForwardUnixSocketPathKey
        var record = stored(traits)
        record.sshConfig = sshTunnel()
        record.sshTunnelMode = .inline(sshTunnel())
        record.additionalFields[key] = "/var/run/postgresql/.s.PGSQL.5432"
        var fresh = record
        fresh.sshTunnelMode = .disabled
        fresh.sshConfig.enabled = false
        fresh.socksProxyMode = .inline(SOCKSProxyConfiguration(host: "proxy.example.com", port: 1_080, username: ""))

        let result = merged(stored: record, fresh: fresh, traits: traits) { $0.name = "Renamed" }
        #expect(result.switchedOnTransports == [.socksProxy])
        #expect(result.additionalFields[key] != nil)

        let outcome = enforce(result, traits)
        #expect(outcome.record.additionalFields[key] == nil)
        #expect(outcome.record.switchedOnTransports == [.socksProxy])
        #expect(enforce(record, traits).record.additionalFields[key] == record.additionalFields[key])
    }

    @Test("A local socket path goes once a transport is on, which a connect would use instead")
    func localSocketPathGoesWithATransport() {
        let traits = probeTraits { $0.defaultLocalSocketPath = "/tmp/mysql.sock" }
        var record = stored(traits)
        record.additionalFields[MySQLLocalSocket.fieldKey] = "/tmp/mysql.sock"
        var fresh = record
        fresh.sshConfig = sshTunnel()
        fresh.sshTunnelMode = .inline(sshTunnel())

        let result = merged(stored: record, fresh: fresh, traits: traits) { $0.name = "Renamed" }
        #expect(result.additionalFields[MySQLLocalSocket.fieldKey] == "/tmp/mysql.sock")
        #expect(result.switchedOnTransports == [.ssh])

        let outcome = enforce(result, traits)
        #expect(outcome.record.additionalFields[MySQLLocalSocket.fieldKey] == nil)
        #expect(outcome.record.switchedOnTransports == [.ssh])
        #expect(enforce(record, traits).record.additionalFields[MySQLLocalSocket.fieldKey] == "/tmp/mysql.sock")
    }

    @Test("A type that opens no remote file keeps no remote file path on its SSH tunnel")
    func remoteFilePathNeedsRemoteFiles() {
        let traits = probeTraits()
        let record = stored(traits)
        var fresh = record
        fresh.sshConfig = sshTunnel(remoteFilePath: "/srv/app.db")
        fresh.sshTunnelMode = .inline(sshTunnel(remoteFilePath: "/srv/app.db"))

        let result = merged(stored: record, fresh: fresh, traits: traits) { $0.name = "Renamed" }
        #expect(result.resolvedSSHConfig.remoteFilePath == "/srv/app.db")

        let outcome = enforce(result, traits)
        #expect(outcome.record.resolvedSSHConfig.remoteFilePath.isEmpty)
        #expect(outcome.record.sshConfig.remoteFilePath.isEmpty)
        #expect(outcome.record.switchedOnTransports == [.ssh])

        var remoteFiles = traits
        remoteFiles.supportsRemoteDatabaseFile = true
        #expect(enforce(result, remoteFiles).record.resolvedSSHConfig.remoteFilePath == "/srv/app.db")
    }

    // MARK: - Host list

    @Test("Host and Port are the first entry of the host list")
    func hostAndPortFollowTheHostList() {
        let traits = probeTraits {
            $0.fields = [ConnectionField(id: "hosts", label: "Hosts", fieldType: .hostList, section: .connection)]
        }
        var record = stored(traits)
        record.host = "a.example.com"
        record.additionalFields["hosts"] = "a.example.com:5000"
        var fresh = record
        fresh.host = "b.example.com"

        let result = merged(stored: record, fresh: fresh, traits: traits) {
            $0.setFieldValue("a.example.com:5000,c.example.com:5001", for: "hosts")
        }
        #expect(result.host == "b.example.com")

        let outcome = enforce(result, traits)
        #expect(outcome.record.host == "a.example.com")
        #expect(outcome.record.port == 5_000)
    }

    // MARK: - Sign-in

    @Test("A connection linked to a credential profile carries that profile's username")
    func linkedProfileOwnsTheUsername() {
        let traits = probeTraits()
        let profile = CredentialProfile(name: "Shared", username: "app")
        var context = EditorContext()
        context.credentialProfiles = [profile]
        let record = stored(traits)
        var fresh = record
        fresh.username = "renamed-elsewhere"

        let result = merged(stored: record, fresh: fresh, traits: traits, context: context) {
            $0.setCredentialMode(.profile(id: profile.id))
        }
        #expect(result.credentialMode == .profile(id: profile.id))
        #expect(result.username == "renamed-elsewhere")

        #expect(enforce(result, traits, context: context).record.username == "app")
    }

    @Test("Ask Every Time stays only where the form shows a password")
    func promptNeedsAShownPassword() {
        let traits = probeTraits {
            $0.fields = [ConnectionField(
                id: "useAgent",
                label: "Use Agent",
                defaultValue: "false",
                fieldType: .toggle,
                section: .authentication,
                hidesPassword: true
            )]
        }
        let record = stored(traits)
        var fresh = record
        fresh.promptForPassword = true

        let result = merged(stored: record, fresh: fresh, traits: traits) { $0.setFieldValue("true", for: "useAgent") }
        #expect(result.promptForPassword)
        #expect(result.additionalFields["useAgent"] == "true")

        let outcome = enforce(result, traits)
        #expect(!outcome.record.promptForPassword)
        #expect(outcome.record.additionalFields["useAgent"] == "true")
        #expect(enforce(fresh, traits).record.promptForPassword)
    }

    @Test("Test drops a password source a prompt or a profile would never run; Save keeps it")
    func testRecordDropsAnUnusedPasswordSource() {
        let traits = probeTraits()
        var record = stored(traits)
        record.passwordSource = .env(variable: "DB_PASSWORD")

        let result = merged(stored: record, fresh: record, traits: traits) { $0.setPasswordPrompt(true, traits: traits) }
        #expect(result.promptForPassword)
        #expect(result.passwordSource != nil)

        #expect(enforce(result, traits, use: .test).record.passwordSource == nil)
        #expect(enforce(result, traits).record.passwordSource == record.passwordSource)
        #expect(enforce(record, traits, use: .test).record.passwordSource == record.passwordSource)
    }

    // MARK: - No-op

    @Test("A record that keeps every rule comes back unchanged")
    func cleanRecordIsUnchanged() {
        let traits = probeTraits {
            $0.fields = [
                ConnectionField(id: "apiToken", label: "API Token", secure: true, section: .authentication),
                ConnectionField(id: "region", label: "Region", section: .connection)
            ]
        }
        var record = stored(traits)
        record.sshConfig = sshTunnel()
        record.sshTunnelMode = .inline(sshTunnel())
        record.additionalFields["region"] = "eu-west-1"
        record.additionalFields[DatabaseConnection.sshForwardUnixSocketPathKey] = "/tmp/.s.PGSQL.5432"
        record.promptForPassword = true
        record.passwordSource = .env(variable: "DB_PASSWORD")

        let outcome = enforce(record, traits)
        #expect(outcome.record == record)
        #expect(outcome.plaintextSecrets.isEmpty)
    }
}
