import Testing
@testable import TableProMSSQLCore

@Suite("MSSQL Kerberos realm")
struct MSSQLKerberosRealmTests {
    @Test("A realm that only repeats the host's DNS domain is Heimdal's guess, not configuration")
    func domainDerivedRealmIsNotConfigured() {
        #expect(!MSSQLKerberosRealm.isConfigured("CORP.CONTOSO.LOCAL", forHost: "sql.corp.contoso.local"))
        #expect(!MSSQLKerberosRealm.isConfigured("EXAMPLE.COM", forHost: "sql.example.com"))
    }

    @Test("A realm that differs from the host's DNS domain came from the Kerberos configuration")
    func mappedRealmIsConfigured() {
        #expect(MSSQLKerberosRealm.isConfigured("RESOURCE.REALM.COM", forHost: "sql.example.com"))
        #expect(MSSQLKerberosRealm.isConfigured("AD.CONTOSO.COM", forHost: "sql.corp.contoso.local"))
    }

    @Test("Realm comparison ignores case, so a lower-cased mapping is still treated as the guess")
    func comparisonIgnoresCase() {
        #expect(!MSSQLKerberosRealm.isConfigured("example.com", forHost: "sql.example.com"))
        #expect(!MSSQLKerberosRealm.isConfigured(" Example.Com ", forHost: "sql.example.com"))
    }

    @Test("An empty realm is never adopted")
    func emptyRealmIsNotConfigured() {
        #expect(!MSSQLKerberosRealm.isConfigured("", forHost: "sql.example.com"))
        #expect(!MSSQLKerberosRealm.isConfigured("   ", forHost: "sql.example.com"))
    }

    @Test("A dot-less host has no domain to guess from, so any realm must be configured")
    func shortHostAlwaysConfigured() {
        #expect(MSSQLKerberosRealm.isConfigured("AD.CONTOSO.COM", forHost: "sqlhost"))
        #expect(MSSQLKerberosRealm.domainGuess(forHost: "sqlhost") == nil)
    }

    @Test("The domain guess is every label after the first, upper-cased")
    func domainGuessDropsOnlyTheFirstLabel() {
        #expect(MSSQLKerberosRealm.domainGuess(forHost: "a.b.c.d.com") == "B.C.D.COM")
        #expect(MSSQLKerberosRealm.domainGuess(forHost: "sql.example.com") == "EXAMPLE.COM")
        #expect(MSSQLKerberosRealm.domainGuess(forHost: " sql.example.com ") == "EXAMPLE.COM")
        #expect(MSSQLKerberosRealm.domainGuess(forHost: "sql.") == nil)
    }
}
