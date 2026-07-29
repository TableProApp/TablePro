//
//  SnowflakeAuthTests.swift
//  TableProTests
//
//  Tests for SnowflakeAccount, SnowflakeConnectionsTOML, and the SPKI
//  wrapping used for key-pair JWT fingerprints (compiled via symlink from
//  SnowflakeDriverPlugin).
//

import Foundation
import Testing

@Suite("Snowflake Account Parsing")
struct SnowflakeAccountTests {
    @Test("Plain locator gets the Snowflake domain appended")
    func testHostFromLocator() {
        #expect(SnowflakeAccount.host(forAccount: "xy12345.us-east-1") == "xy12345.us-east-1.snowflakecomputing.com")
        #expect(SnowflakeAccount.host(forAccount: "myorg-myaccount") == "myorg-myaccount.snowflakecomputing.com")
    }

    @Test("Full hostnames pass through unchanged, case-insensitively")
    func testHostPassthrough() {
        #expect(
            SnowflakeAccount.host(forAccount: "abc.snowflakecomputing.com") == "abc.snowflakecomputing.com"
        )
        #expect(
            SnowflakeAccount.host(forAccount: "Abc.SnowflakeComputing.Com") == "Abc.SnowflakeComputing.Com"
        )
    }

    @Test("URL forms resolve to their host")
    func testHostFromURL() {
        #expect(
            SnowflakeAccount.host(forAccount: "https://abc.snowflakecomputing.com/console") ==
                "abc.snowflakecomputing.com"
        )
    }

    @Test("Whitespace is trimmed before resolution")
    func testHostTrimsWhitespace() {
        #expect(SnowflakeAccount.host(forAccount: "  abc \n") == "abc.snowflakecomputing.com")
    }

    @Test("Issuer account name drops domain and region, then uppercases")
    func testIssuerAccountName() {
        #expect(SnowflakeAccount.issuerAccountName(forAccount: "xy12345.us-east-1") == "XY12345")
        #expect(
            SnowflakeAccount.issuerAccountName(forAccount: "xy12345.us-east-1.snowflakecomputing.com") == "XY12345"
        )
        #expect(SnowflakeAccount.issuerAccountName(forAccount: "myorg-myaccount") == "MYORG-MYACCOUNT")
    }
}

@Suite("Snowflake Connections TOML")
struct SnowflakeConnectionsTOMLTests {
    @Test("Parses sections with key-value pairs")
    func testBasicSection() {
        let toml = """
            [default]
            account = "xy12345"
            user = jane
            """
        let parsed = SnowflakeConnectionsTOML.parse(toml)
        #expect(parsed["default"]?["account"] == "xy12345")
        #expect(parsed["default"]?["user"] == "jane")
    }

    @Test("Strips the connections. prefix from config.toml sections")
    func testConnectionsPrefix() {
        let parsed = SnowflakeConnectionsTOML.parse("[connections.dev]\naccount = 'abc'\n")
        #expect(parsed["dev"]?["account"] == "abc")
    }

    @Test("Quoted section names are unquoted")
    func testQuotedSectionName() {
        let parsed = SnowflakeConnectionsTOML.parse("[connections.\"my conn\"]\nrole = \"ADMIN\"\n")
        #expect(parsed["my conn"]?["role"] == "ADMIN")
    }

    @Test("Comments are stripped outside strings and kept inside both quote styles")
    func testCommentHandling() {
        let toml = """
            [default]
            account = "abc" # trailing comment
            password = "p#ss"
            token = 'a#b'
            """
        let parsed = SnowflakeConnectionsTOML.parse(toml)
        #expect(parsed["default"]?["account"] == "abc")
        #expect(parsed["default"]?["password"] == "p#ss")
        #expect(parsed["default"]?["token"] == "a#b")
    }

    @Test("Key-value pairs before any section are ignored")
    func testKeysOutsideSectionIgnored() {
        let parsed = SnowflakeConnectionsTOML.parse("account = \"abc\"\n[dev]\nuser = \"u\"\n")
        #expect(parsed.count == 1)
        #expect(parsed["dev"]?["user"] == "u")
    }
}

@Suite("Snowflake SPKI Wrapping")
struct SnowflakeSPKIWrappingTests {
    private static let rsaAlgorithmID: [UInt8] = [
        0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86,
        0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00
    ]

    @Test("Short keys use single-byte DER lengths")
    func testShortFormLength() {
        let pkcs1 = Data((0..<10).map { UInt8($0) })
        let spki = [UInt8](SnowflakeKeyPairAuth.wrapPKCS1IntoSPKI(pkcs1))

        #expect(spki[0] == 0x30)
        #expect(Int(spki[1]) == spki.count - 2)
        #expect(Array(spki[2..<17]) == Self.rsaAlgorithmID)
        #expect(spki[17] == 0x03)
        #expect(Int(spki[18]) == pkcs1.count + 1)
        #expect(spki[19] == 0x00)
        #expect(Array(spki.suffix(pkcs1.count)) == [UInt8](pkcs1))
    }

    @Test("Keys past 127 bytes use long-form DER lengths")
    func testLongFormLength() {
        let pkcs1 = Data(repeating: 0xAB, count: 270)
        let spki = [UInt8](SnowflakeKeyPairAuth.wrapPKCS1IntoSPKI(pkcs1))

        #expect(spki[0] == 0x30)
        #expect(spki[1] == 0x82)
        let bodyLength = (Int(spki[2]) << 8) | Int(spki[3])
        #expect(bodyLength == spki.count - 4)
        #expect(Array(spki[4..<19]) == Self.rsaAlgorithmID)
        #expect(spki[19] == 0x03)
        #expect(spki[20] == 0x82)
        let bitStringLength = (Int(spki[21]) << 8) | Int(spki[22])
        #expect(bitStringLength == pkcs1.count + 1)
        #expect(spki[23] == 0x00)
        #expect(Array(spki.suffix(pkcs1.count)) == [UInt8](pkcs1))
    }
}
