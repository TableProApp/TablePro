//
//  DatabaseManagerRDSEndpointTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSSHConfig
import TableProSSHTransport
import Testing

@MainActor
private final class EndpointSignInSpy {
    var answer: ConsentAnswer = .approved
    private(set) var destinations: [String] = []

    func ask(_ question: LocalCredentialQuestion) async -> ConsentAnswer {
        destinations.append(question.destination)
        return answer
    }
}

@MainActor
struct DatabaseManagerRDSEndpointTests {
    private static let alias = "reader.db.example.com"
    private static let replicaA = "replica-a.abc123.us-east-1.rds.amazonaws.com"
    private static let replicaB = "replica-b.abc123.us-east-1.rds.amazonaws.com"

    private func connection(
        type: DatabaseType = .mysql,
        host: String = alias,
        signIn: String? = "profile"
    ) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "RDS", host: host, port: 3_306, type: type)
        connection.additionalFields[DatabaseConnection.iamSignInFieldId] = signIn
        return connection
    }

    @Test("The CNAME host of an AWS IAM connection becomes the RDS endpoint it stands for")
    func directConnectionDialsTheEndpoint() async throws {
        let resolver = FakeCNAMEResolver([Self.alias: Self.replicaA])
        let manager = DatabaseManager(cnameResolver: resolver)

        let effective = try await manager.resolvingRDSEndpointAlias(of: connection(), trigger: .request)

        #expect(effective.host == Self.replicaA)
        #expect(effective.port == 3_306)
        #expect(resolver.queried == [Self.alias])
    }

    @Test("Every lookup follows the CNAME again, so a moved CNAME gives the new endpoint and the saved row keeps its host")
    func movedCNAMEIsFollowed() async throws {
        let resolver = FakeCNAMEResolver([Self.alias: Self.replicaA])
        let manager = DatabaseManager(cnameResolver: resolver)
        let saved = connection()

        let first = try await manager.resolvingRDSEndpointAlias(of: saved, trigger: .request)
        resolver.point(Self.alias, at: Self.replicaB)
        let second = try await manager.resolvingRDSEndpointAlias(of: saved, trigger: .request)

        #expect(first.host == Self.replicaA)
        #expect(second.host == Self.replicaB)
        #expect(saved.host == Self.alias)
    }

    @Test("A host with no RDS endpoint behind it is dialled and signed as typed")
    func unresolvedHostIsUnchanged() async throws {
        let manager = DatabaseManager(cnameResolver: FakeCNAMEResolver())

        let effective = try await manager.resolvingRDSEndpointAlias(of: connection(), trigger: .request)

        #expect(effective.host == Self.alias)
    }

    @Test("Nothing is looked up without an RDS token: password sign-in, Google IAM, Redshift, ElastiCache, Keyspaces")
    func otherSignInsAreNotLookedUp() async throws {
        let resolver = FakeCNAMEResolver([Self.alias: Self.replicaA])
        let manager = DatabaseManager(cnameResolver: resolver)
        let untouched = [
            connection(signIn: nil),
            connection(signIn: GoogleCloudSQLAuthFields.applicationDefault),
            connection(type: .redshift),
            connection(type: .redis),
            connection(type: .cassandra)
        ]

        for saved in untouched {
            let effective = try await manager.resolvingRDSEndpointAlias(of: saved, trigger: .request)
            #expect(effective.host == Self.alias)
        }
        #expect(resolver.queried.isEmpty)
    }

    @Test("Behind a tunnel the far end resolves the name, so the forward keeps the name as typed")
    func tunnelKeepsTheTypedName() async throws {
        let resolver = FakeCNAMEResolver([Self.alias: Self.replicaA])
        let manager = DatabaseManager(cnameResolver: resolver)
        var saved = connection(type: .postgresql)
        saved.port = 5_432
        saved.sshTunnelMode = .inline(SSHConfiguration(enabled: true, host: "bastion.example.com"))

        let resolved = try await manager.resolvingRDSEndpointAlias(of: saved, trigger: .request)

        #expect(resolved.sshForwardDestination == .tcp(host: Self.alias, port: 5_432))
        #expect(resolver.queried.isEmpty)
    }

    @Test("The lookup runs for exactly the connections the minter gives an RDS token")
    func lookupMatchesTheMinter() {
        for type in [DatabaseType.mysql, .mariadb, .postgresql, .redshift, .redis, .cassandra, .scylladb] {
            for signIn in ["profile", "accessKey", "sso", GoogleCloudSQLAuthFields.applicationDefault, nil] {
                let saved = connection(type: type, signIn: signIn)
                let minter = ConnectionCredentialResolver.iamPasswordMinter(for: saved, fields: saved.additionalFields)
                var mintsRDSToken = false
                if case .aws(let signer) = minter, case .rds = signer.target {
                    mintsRDSToken = true
                }
                #expect(ConnectionCredentialResolver.signsRDSToken(for: saved) == mintsRDSToken, "\(type) \(signIn ?? "password")")
            }
        }
    }

    @Test("An endpoint counts as moved only when the dialled host changes, whatever its case")
    func movedEndpointIsTheDialledHost() {
        let manager = DatabaseManager(cnameResolver: FakeCNAMEResolver())
        var dialled = connection()
        dialled.host = Self.replicaA
        var session = ConnectionSession(connection: connection())
        session.effectiveConnection = dialled

        var moved = dialled
        moved.host = Self.replicaB
        var sameInCapitals = dialled
        sameInCapitals.host = Self.replicaA.uppercased()

        #expect(manager.movesEndpoint(of: session, to: moved))
        #expect(!manager.movesEndpoint(of: session, to: sameInCapitals))
        #expect(!manager.movesEndpoint(of: ConnectionSession(connection: connection()), to: connection()))
    }

    @Test("A failed lookup is an error that names the host, not a token signed for the CNAME")
    func failedLookupThrows() async {
        let manager = DatabaseManager(cnameResolver: FakeCNAMEResolver(failing: [Self.alias]))

        await #expect(throws: AWSAuthError.endpointLookupFailed(host: Self.alias)) {
            _ = try await manager.resolvingRDSEndpointAlias(of: connection(), trigger: .request)
        }
    }

    @Test("AWS IAM signs in only with a value the type's own Authentication picker offers")
    func signInNeedsTheTypesOwnPicker() {
        #expect(connection(type: .mysql, signIn: "profile").iamSignIn == .aws(source: "profile"))
        #expect(connection(type: .postgresql, signIn: GoogleCloudSQLAuthFields.applicationDefault).iamSignIn
            == .googleCloud(.applicationDefault))
        // ScyllaDB has no AWS picker, but its plugin signs in to Keyspaces with the field, so TLS is still raised.
        #expect(connection(type: .scylladb, signIn: "profile").iamSignIn == .aws(source: "profile"))
        for (type, signIn) in [
            (DatabaseType.redis, GoogleCloudSQLAuthFields.applicationDefault),
            (DatabaseType.mariadb, GoogleCloudSQLAuthFields.serviceAccount),
            (DatabaseType(rawValue: "Elasticsearch"), "profile"),
            (DatabaseType.mssql, "profile"),
            (DatabaseType.mysql, "someday"),
            (DatabaseType.scylladb, GoogleCloudSQLAuthFields.applicationDefault)
        ] {
            let saved = connection(type: type, signIn: signIn)
            #expect(saved.iamSignIn == nil, "\(type) \(signIn)")
            #expect(ConnectionCredentialResolver.iamPasswordMinter(for: saved, fields: saved.additionalFields) == nil)
        }
    }

    @Test("A row from someone else asks again for each RDS endpoint its CNAME leads to, and never from the background")
    func sharedRowApprovesEachEndpoint() async throws {
        let suite = try EphemeralDefaults()
        let spy = EndpointSignInSpy()
        let consent = LocalCredentialConsent(
            approvals: ConnectionApprovalStore(kind: .localCredentials, defaults: suite.defaults, savedConnections: { [] }),
            ask: { [spy] question in await spy.ask(question) }
        )
        let resolver = FakeCNAMEResolver([Self.alias: Self.replicaA])
        let manager = DatabaseManager(localCredentialConsent: consent, cnameResolver: resolver)
        var shared = connection()
        shared.origin = .teamLibrary

        let first = try await manager.resolvingRDSEndpointAlias(of: shared, trigger: .request)
        let again = try await manager.resolvingRDSEndpointAlias(of: shared, trigger: .background)
        resolver.point(Self.alias, at: Self.replicaB)
        await #expect(throws: LocalCredentialConsentError.needsPerson) {
            _ = try await manager.resolvingRDSEndpointAlias(of: shared, trigger: .background)
        }
        spy.answer = .declined
        await #expect(throws: LocalCredentialConsentError.declined) {
            _ = try await manager.resolvingRDSEndpointAlias(of: shared, trigger: .request)
        }

        #expect(first.host == Self.replicaA)
        #expect(again.host == Self.replicaA)
        #expect(spy.destinations.count == 2)
        #expect(spy.destinations.allSatisfy { !$0.contains(Self.alias) })
        #expect(spy.destinations.first?.contains(Self.replicaA) == true)
        #expect(spy.destinations.last?.contains(Self.replicaB) == true)
    }

    @Test("A row made on this Mac follows its own CNAME without asking")
    func ownRowDoesNotAsk() async throws {
        let suite = try EphemeralDefaults()
        let spy = EndpointSignInSpy()
        let consent = LocalCredentialConsent(
            approvals: ConnectionApprovalStore(kind: .localCredentials, defaults: suite.defaults, savedConnections: { [] }),
            ask: { [spy] question in await spy.ask(question) }
        )
        let manager = DatabaseManager(
            localCredentialConsent: consent,
            cnameResolver: FakeCNAMEResolver([Self.alias: Self.replicaA])
        )

        let effective = try await manager.resolvingRDSEndpointAlias(of: connection(), trigger: .background)

        #expect(effective.host == Self.replicaA)
        #expect(spy.destinations.isEmpty)
    }

    private func approvingManager(failingLookup: Bool) throws -> (DatabaseManager, EphemeralDefaults) {
        let suite = try EphemeralDefaults()
        let consent = LocalCredentialConsent(
            approvals: ConnectionApprovalStore(kind: .localCredentials, defaults: suite.defaults, savedConnections: { [] }),
            ask: { _ in .approved }
        )
        let resolver = FakeCNAMEResolver(failing: failingLookup ? [Self.alias] : [])
        return (DatabaseManager(localCredentialConsent: consent, cnameResolver: resolver), suite)
    }

    @Test("Connect, Test Connection and both reconnects look the CNAME up before they dial")
    func everyDialPathLooksUp() async throws {
        let (manager, suite) = try approvingManager(failingLookup: true)
        defer { withExtendedLifetime(suite) {} }
        let lookupFailed = AWSAuthError.endpointLookupFailed(host: Self.alias)
        let saved = connection()

        await #expect(throws: lookupFailed) {
            try await manager.connectToSession(saved, trigger: .request)
        }
        manager.removeSession(for: saved.id)

        await #expect(throws: lookupFailed) {
            _ = try await manager.testConnection(saved)
        }

        var session = ConnectionSession(connection: saved, driver: MockDatabaseDriver())
        session.status = .connected
        manager.injectSession(session, for: saved.id)
        defer { manager.removeSession(for: saved.id) }
        let generation = manager.connectionAttempts.begin(for: saved.id)
        await #expect(throws: lookupFailed) {
            _ = try await manager.reconnectDriver(for: session, allowsCredentialPrompt: false, generation: generation)
        }
        manager.connectionAttempts.finish(generation, for: saved.id)

        await #expect(throws: lookupFailed) {
            try await manager.reconnectSession(saved.id)
        }
    }
}

