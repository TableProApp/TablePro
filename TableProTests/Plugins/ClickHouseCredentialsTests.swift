//
//  ClickHouseCredentialsTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("ClickHouse Credentials")
struct ClickHouseCredentialsTests {
    @Test("A blank username resolves to the ClickHouse default user")
    func blankUsernameResolvesToDefaultUser() {
        #expect(ClickHouseCredentials.effectiveUsername("") == "default")
    }

    @Test("An explicit username is used as given")
    func explicitUsernameIsPreserved() {
        #expect(ClickHouseCredentials.effectiveUsername("analytics") == "analytics")
    }

    @Test("Basic authorization for a blank username authenticates as default")
    func basicAuthorizationForBlankUsername() throws {
        let header = try #require(ClickHouseCredentials.basicAuthorizationHeader(username: "", password: "secret"))
        let encoded = header.replacingOccurrences(of: "Basic ", with: "")
        let data = try #require(Data(base64Encoded: encoded))
        #expect(String(data: data, encoding: .utf8) == "default:secret")
    }

    @Test("Basic authorization keeps an explicit username")
    func basicAuthorizationForExplicitUsername() throws {
        let header = try #require(ClickHouseCredentials.basicAuthorizationHeader(username: "analytics", password: ""))
        let encoded = header.replacingOccurrences(of: "Basic ", with: "")
        let data = try #require(Data(base64Encoded: encoded))
        #expect(String(data: data, encoding: .utf8) == "analytics:")
    }
}
