import Foundation
@testable import TablePro
import Testing

@MainActor
struct ConnectionCredentialResolverPgpassTests {
    @Test("Only engines that declare the pgpass field read ~/.pgpass")
    func pgpassBelongsToThePostgreSQLFamily() {
        #expect(ConnectionCredentialResolver.readsPgpass(TestFixtures.makeConnection(type: .postgresql)))
        #expect(ConnectionCredentialResolver.readsPgpass(TestFixtures.makeConnection(type: .redshift)))
        #expect(!ConnectionCredentialResolver.readsPgpass(TestFixtures.makeConnection(type: .redis)))
        #expect(!ConnectionCredentialResolver.readsPgpass(TestFixtures.makeConnection(type: .mongodb)))
        #expect(!ConnectionCredentialResolver.readsPgpass(TestFixtures.makeConnection(type: .mysql)))
    }

    @Test("A pgpass profile asks for the password on an engine that can dial hosts ~/.pgpass never saw")
    func pgpassProfileAsksOutsideThePostgreSQLFamily() throws {
        let profile = CredentialProfile(name: "pgpass \(UUID().uuidString)", username: "app", passwordMode: .pgpass)
        let profiles = CredentialProfileStorage.shared
        try #require(profiles.addProfile(profile))
        defer { _ = profiles.deleteProfile(profile) }

        var redis = TestFixtures.makeConnection(type: .redis)
        redis.credentialMode = .profile(id: profile.id)
        var postgres = TestFixtures.makeConnection(type: .postgresql)
        postgres.credentialMode = .profile(id: profile.id)

        #expect(ConnectionCredentialResolver.promptsForPassword(redis))
        #expect(!ConnectionCredentialResolver.promptsForPassword(postgres))
    }
}
