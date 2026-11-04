import Foundation
import TableProHTTP
import TableProSnowflakeCore
import Testing

struct SnowflakeAccountTests {
    @Test("An account identifier, host or URL resolves to its Snowflake host", arguments: [
        ("myorg-myaccount", "myorg-myaccount.snowflakecomputing.com", "MYORG-MYACCOUNT"),
        ("  XY12345.us-east-2.aws\n", "xy12345.us-east-2.aws.snowflakecomputing.com", "XY12345"),
        ("myorg-my_account.privatelink", "myorg-my_account.privatelink.snowflakecomputing.com", "MYORG-MY_ACCOUNT"),
        ("Acme.SnowflakeComputing.com", "acme.snowflakecomputing.com", "ACME"),
        ("https://acme.snowflakecomputing.com/", "acme.snowflakecomputing.com", "ACME"),
        ("https://xy12345.cn-north-1.snowflakecomputing.cn", "xy12345.cn-north-1.snowflakecomputing.cn", "XY12345"),
    ])
    func resolves(text: String, host: String, name: String) throws {
        let account = try #require(SnowflakeAccount(text))
        #expect(account.host == host)
        #expect(account.name == name)
        #expect(account.origin.scheme == "https")
        #expect(account.origin.host == host)
        #expect(account.origin.port == 443)
    }

    @Test("An account that would send the login anywhere but a Snowflake host is refused", arguments: [
        "x@collector.example/.snowflakecomputing.com",
        "acme.x@collector.example/.snowflakecomputing.com",
        "acme.x://collector.example",
        "https://login.attacker.example",
        "https://x@acme.snowflakecomputing.com",
        "https://acme.snowflakecomputing.com:8443",
        "https://acme.snowflakecomputing.com/path",
        "http://acme.snowflakecomputing.com",
        "collector.example%2F.snowflakecomputing.com",
        "acme/x",
        "acme:443",
        "acme..aws",
        "acme.snowflakecomputing.com.",
        "a.b.c.d.e",
        "",
    ])
    func refuses(text: String) {
        #expect(SnowflakeAccount(text) == nil)
    }

    @Test("Cached tokens are keyed by host, so accounts sharing a first label never share one")
    func tokenKeys() throws {
        let acme = try #require(SnowflakeAccount("acme"))
        let regional = try #require(SnowflakeAccount("acme.us-east-1"))
        #expect(acme.tokenKey(user: "bob") == "acme.snowflakecomputing.com|BOB")
        #expect(regional.tokenKey(user: "bob") == "acme.us-east-1.snowflakecomputing.com|BOB")
        #expect(acme.tokenKey(user: "bob") != regional.tokenKey(user: "bob"))
    }

    @Test("Only a bare identifier on the default domain reads a token cached under the old key")
    func legacyTokenKeys() throws {
        #expect(try #require(SnowflakeAccount("acme")).legacyTokenKey(user: "bob") == "ACME.BOB")
        #expect(try #require(SnowflakeAccount("acme.snowflakecomputing.com")).legacyTokenKey(user: "bob") == "ACME.BOB")
        #expect(try #require(SnowflakeAccount("acme.us-east-1")).legacyTokenKey(user: "bob") == nil)
        #expect(try #require(SnowflakeAccount("acme.snowflakecomputing.cn")).legacyTokenKey(user: "bob") == nil)
    }
}
