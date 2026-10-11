//
//  ServerDashboardQueryProviderFactoryTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

/// The support question is asked on every toolbar and menu validation pass, so it is answered
/// without building a provider. It has to give the answer building one would.
@MainActor
struct ServerDashboardQueryProviderFactoryTests {
    @Test("Support is answered without a provider, and agrees with building one for every known engine")
    func supportAgreesWithTheProvider() {
        let types = DatabaseType.allKnownTypes
        #expect(types.count > 10, "Only \(types.count) known types; the walk would pass vacuously")
        for type in types {
            #expect(
                ServerDashboardQueryProviderFactory.supportsDashboard(for: type)
                    == (ServerDashboardQueryProviderFactory.provider(for: type) != nil),
                "\(type.rawValue)"
            )
        }
    }

    @Test("An engine no plugin has heard of has no dashboard")
    func unknownEngineHasNone() {
        let unknown = DatabaseType(rawValue: "com.example.not-a-database")
        #expect(!ServerDashboardQueryProviderFactory.supportsDashboard(for: unknown))
        #expect(ServerDashboardQueryProviderFactory.provider(for: unknown) == nil)
    }

    @Test("PostgreSQL, MySQL and SQLite each have one")
    func knownEnginesHaveOne() {
        for type in [DatabaseType.postgresql, .mysql, .mariadb, .sqlite, .redshift, .cockroachdb] {
            #expect(ServerDashboardQueryProviderFactory.supportsDashboard(for: type), "\(type.rawValue)")
        }
    }
}
