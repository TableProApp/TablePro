//
//  ConnectionFormTransportTests.swift
//  TableProTests
//
//  A connection reaches its database through exactly one transport. Two enabled at once made
//  `DatabaseConnection.activeTunnelKind` answer nil, and `activeTunnelManager` then opened a
//  direct connection to the database host while the form reported both as on.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
@Suite("Connection form transport")
struct ConnectionFormTransportTests {
    private func coordinator(type: DatabaseType = .mysql) -> ConnectionFormCoordinator {
        let coordinator = ConnectionFormCoordinator(connectionId: nil)
        coordinator.network.type = type
        return coordinator
    }

    private func enabledFlags(_ coordinator: ConnectionFormCoordinator) -> [ConnectionTunnelKind] {
        var kinds: [ConnectionTunnelKind] = []
        if coordinator.ssh.state.enabled { kinds.append(.ssh) }
        if coordinator.cloudflareTunnel.state.enabled { kinds.append(.cloudflare) }
        if coordinator.cloudSQLProxy.state.enabled { kinds.append(.cloudSQLProxy) }
        if coordinator.socksProxy.state.enabled { kinds.append(.socksProxy) }
        if coordinator.tunnelCommand.state.enabled { kinds.append(.tunnelCommand) }
        return kinds
    }

    @Test("a new connection is direct")
    func defaultsToDirect() {
        let coordinator = coordinator()
        #expect(coordinator.transport == nil)
        #expect(enabledFlags(coordinator).isEmpty)
    }

    @Test("selecting a transport enables exactly that one")
    func selectionIsExclusive() {
        for kind in ConnectionTunnelKind.formToggleable {
            let coordinator = coordinator()
            coordinator.transport = kind
            #expect(enabledFlags(coordinator) == [kind], "\(kind) did not enable alone")
            #expect(coordinator.transport == kind, "\(kind) did not round-trip")
        }
    }

    @Test("switching transport disables the previous one")
    func switchingDisablesPrevious() {
        for first in ConnectionTunnelKind.formToggleable {
            for second in ConnectionTunnelKind.formToggleable where second != first {
                let coordinator = coordinator()
                coordinator.transport = first
                coordinator.transport = second
                #expect(enabledFlags(coordinator) == [second], "\(first) survived a switch to \(second)")
            }
        }
    }

    @Test("selecting direct disables every transport")
    func directDisablesEverything() {
        let coordinator = coordinator()
        coordinator.transport = .socksProxy
        coordinator.transport = nil
        #expect(coordinator.transport == nil)
        #expect(enabledFlags(coordinator).isEmpty)
    }

    @Test("switching away keeps the transport's configuration for switching back")
    func switchingPreservesConfiguration() {
        let coordinator = coordinator()
        coordinator.transport = .ssh
        coordinator.ssh.state.host = "bastion.example.com"
        coordinator.ssh.state.username = "deploy"

        coordinator.transport = .socksProxy
        #expect(coordinator.ssh.state.host == "bastion.example.com")

        coordinator.transport = .ssh
        #expect(coordinator.ssh.state.host == "bastion.example.com")
        #expect(coordinator.ssh.state.username == "deploy")
    }

    @Test("a connection stored with two transports normalizes to one")
    func normalizeCollapsesLegacyMultiTransport() {
        let coordinator = coordinator()
        coordinator.ssh.state.enabled = true
        coordinator.socksProxy.state.enabled = true
        coordinator.tunnelCommand.state.enabled = true

        coordinator.normalizeTransport()

        #expect(enabledFlags(coordinator) == [.ssh])
        #expect(coordinator.transport == .ssh)
    }

    @Test("a transport the type no longer offers falls back to direct")
    func normalizeDropsUnavailableTransport() {
        let coordinator = coordinator()
        coordinator.transport = .cloudflare
        coordinator.network.type = .sqlite

        coordinator.normalizeTransport()

        #expect(coordinator.transport == nil)
        #expect(enabledFlags(coordinator).isEmpty)
    }

    @Test("direct is always offered, exactly once, and never duplicated")
    func availableTransportsAreWellFormed() {
        for type in DatabaseType.allKnownTypes {
            let coordinator = coordinator(type: type)
            let available = coordinator.availableTransports
            #expect(available.first == .some(nil), "\(type.rawValue) does not offer direct first")
            #expect(Set(available).count == available.count, "\(type.rawValue) offers a duplicate transport")
        }
    }

    @Test("a file-based type offers the remote file transport rather than a port forward")
    func fileBasedTypeUsesRemoteFile() {
        let coordinator = coordinator(type: .sqlite)
        #expect(coordinator.availableTransports.contains(.remoteFile))
        #expect(!coordinator.availableTransports.contains(.ssh))

        coordinator.transport = .remoteFile
        #expect(coordinator.ssh.state.enabled)
        #expect(coordinator.transport == .remoteFile)
    }

    @Test("leaving the SSH server clears the remote file path it was carrying")
    func leavingSSHClearsRemoteFilePath() {
        let coordinator = coordinator(type: .sqlite)
        coordinator.transport = .remoteFile
        coordinator.ssh.state.remoteFilePath = "/var/db/app.sqlite"

        coordinator.transport = nil

        #expect(coordinator.ssh.state.remoteFilePath.isEmpty)
    }

    @Test("selecting a transport clears a passing test result")
    func selectionInvalidatesTestResult() {
        let coordinator = coordinator()
        coordinator.testSucceeded = true
        coordinator.transport = .ssh
        #expect(!coordinator.testSucceeded)
    }

    @Test("the SSH server is offered as one transport, never as both of its flavours")
    func sshAndRemoteFileAreNeverOfferedTogether() {
        for type in DatabaseType.allKnownTypes {
            let available = coordinator(type: type).availableTransports
            #expect(
                !(available.contains(.ssh) && available.contains(.remoteFile)),
                "\(type.rawValue) offers both SSH flavours, so the picker cannot round-trip"
            )
        }
    }

    @Test("changing the database type returns the connection to direct")
    func typeChangeResetsTransport() {
        let coordinator = coordinator()
        coordinator.transport = .ssh
        coordinator.ssh.state.host = "bastion.example.com"

        coordinator.network.setType(.sqlite)

        #expect(coordinator.transport == nil, "A transport means something else on another type")
        #expect(enabledFlags(coordinator).isEmpty)
        #expect(coordinator.ssh.state.host == "bastion.example.com", "The server itself is kept")
    }

    @Test("changing the type clears a remote file path the new type cannot open")
    func typeChangeClearsRemoteFilePath() {
        let coordinator = coordinator(type: .sqlite)
        coordinator.transport = .remoteFile
        coordinator.ssh.state.remoteFilePath = "/var/db/app.sqlite"

        coordinator.network.setType(.mysql)

        #expect(coordinator.ssh.state.remoteFilePath.isEmpty)
    }

    @Test("leaving the port forward clears the socket path only it can reach")
    func leavingSSHClearsForwardSocketPath() {
        let coordinator = coordinator()
        coordinator.transport = .ssh
        coordinator.network.sshForwardUnixSocketPath = "/var/run/postgresql/.s.PGSQL.5432"

        coordinator.transport = .socksProxy

        #expect(coordinator.network.sshForwardUnixSocketPath.isEmpty)
        #expect(!coordinator.network.forwardsToUnixSocket)
    }

    @Test("an enabled transport always has a tab that shows it")
    func anEnabledTransportIsAlwaysReachable() {
        for type in DatabaseType.allKnownTypes {
            let coordinator = coordinator(type: type)
            for kind in coordinator.availableTransports.compactMap({ $0 }) {
                coordinator.transport = kind
                #expect(
                    coordinator.visibleTabs.contains(.network),
                    "\(type.rawValue) hides Network while \(kind.rawValue) is on, so its issues go uncounted"
                )
            }
        }
    }

    /// A retyped connection has to clear the Keychain entries the old type put there, or a
    /// SQL Server connection changed to MySQL leaves its Kerberos password stored under the same
    /// connection id with nothing in the form able to see or clear it.
    @Test("a retyped connection still owns the previous type's secure fields")
    func retypeKeepsOwnershipOfTheOldTypesSecrets() {
        let manager = PluginManager.shared
        var typesWithSecrets: [DatabaseType] = []
        for type in DatabaseType.allKnownTypes
        where manager.additionalConnectionFields(for: type).contains(where: \.isSecure) {
            typesWithSecrets.append(type)
        }
        guard let secretive = typesWithSecrets.first else {
            Issue.record("No known type declares a secure connection field")
            return
        }

        let originalIds = Set(
            manager.additionalConnectionFields(for: secretive).filter(\.isSecure).map(\.id)
        )
        let owned = ConnectionFormCoordinator.secureFieldsOwnedByForm(
            currentType: .mysql,
            originalType: secretive,
            pluginManager: manager
        )

        #expect(originalIds.isSubset(of: Set(owned.map(\.id))))
        #expect(Set(owned.map(\.id)).count == owned.count, "A field shared by both types is listed once")
    }

    @Test("a driver with no SSL section cannot be blocked by an SSL rule")
    func sslIssuesAreSilentWhereThereIsNoSSLSection() {
        let coordinator = coordinator(type: .sqlite)
        coordinator.ssl.mode = .verifyCa
        coordinator.ssl.caCertPath = ""

        #expect(!coordinator.supportsSSL)
        #expect(coordinator.ssl.validationIssues.isEmpty)

        let networked = self.coordinator()
        networked.ssl.mode = .verifyCa
        networked.ssl.caCertPath = ""
        #expect(networked.supportsSSL)
        #expect(!networked.ssl.validationIssues.isEmpty, "A driver that shows the field still requires it")
    }

    @Test("a URL naming an SSH server opens the form on exactly that transport")
    func urlImportSelectsOneTransport() throws {
        let url = "mysql+ssh://deploy@bastion.example.com:22/dbuser@db.internal:3306/app"
        guard case .success(let parsed) = ConnectionURLParser.parse(url) else {
            Issue.record("\(url) should parse")
            return
        }

        let coordinator = ConnectionFormCoordinator(connectionId: nil, initialParsedURL: parsed)
        coordinator.start()

        #expect(coordinator.transport == .ssh)
        #expect(enabledFlags(coordinator) == [.ssh])
        #expect(coordinator.ssh.state.host == "bastion.example.com")
    }

    @Test("every issue that blocks Save is claimed by a visible tab")
    func everyBlockingIssueHasATabToFix() {
        let coordinator = coordinator()
        coordinator.transport = .socksProxy
        coordinator.socksProxy.state.host = ""

        #expect(!coordinator.isFormValid)
        let claimed = coordinator.visibleTabs.flatMap { $0.validationIssues(for: coordinator) }
        #expect(claimed == coordinator.validationIssues)
        #expect(coordinator.firstTabWithIssue != nil)
    }
}
