//
//  VaultClientTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct VaultClientTests {
    @Test("The address comes from the role, else VAULT_ADDR, and the namespace from VAULT_NAMESPACE")
    func endpointResolution() throws {
        let fromRole = try VaultEndpoint.resolve(
            address: "https://vault.corp:8200/",
            environment: ["VAULT_ADDR": "https://other:8200", "VAULT_NAMESPACE": "team-a"]
        )
        #expect(fromRole.address.absoluteString == "https://vault.corp:8200/")
        #expect(fromRole.namespace == "team-a")
        #expect(fromRole.url(forAPIPath: "database/creds/ro")?.absoluteString == "https://vault.corp:8200/v1/database/creds/ro")

        let fromEnvironment = try VaultEndpoint.resolve(address: "  ", environment: ["VAULT_ADDR": "http://127.0.0.1:8200"])
        #expect(fromEnvironment.address.absoluteString == "http://127.0.0.1:8200")
        #expect(fromEnvironment.namespace == nil)

        #expect(throws: VaultError.noAddress) { try VaultEndpoint.resolve(address: nil, environment: [:]) }
        #expect(throws: VaultError.invalidAddress("vault.corp")) {
            try VaultEndpoint.resolve(address: "vault.corp", environment: [:])
        }
    }

    @Test("A proxy path prefix on the address is kept")
    func addressPathPrefix() throws {
        let endpoint = try VaultEndpoint.resolve(address: "https://gw.corp/vault", environment: [:])
        #expect(endpoint.url(forAPIPath: "sys/leases/renew")?.absoluteString == "https://gw.corp/vault/v1/sys/leases/renew")
    }

    @Test("Reading a role returns the lease and both halves of the credential")
    func readsCredentials() async throws {
        let transport = VaultFakeTransport()
        transport.reply("GET", "database/creds/readonly", VaultFixtures.credsReply)
        let endpoint = VaultEndpoint(address: VaultFixtures.endpoint.address, namespace: "team-a")
        let client = VaultClient(endpoint: endpoint, transport: transport)

        let credential = try await client.readCredentials(path: "database/creds/readonly", token: "t0")

        #expect(credential == VaultLeasedCredential(
            leaseId: "database/creds/readonly/abc",
            leaseDuration: .seconds(3_600),
            renewable: true,
            username: "v-token-readonly-1",
            password: "s3cret"
        ))
        let sent = try #require(transport.requests.first)
        #expect(sent.token == "t0")
        #expect(sent.namespace == "team-a")
    }

    @Test("A reply without a username or password is refused rather than signing in with nothing")
    func incompleteCredentials() async {
        let transport = VaultFakeTransport()
        transport.reply("GET", "database/creds/readonly", #"{"lease_id":"x","lease_duration":60,"renewable":true,"data":{"username":"u"}}"#)
        let client = VaultClient(endpoint: VaultFixtures.endpoint, transport: transport)

        await #expect(throws: VaultError.malformedResponse) {
            try await client.readCredentials(path: "database/creds/readonly", token: "t0")
        }
    }

    @Test("Vault's error list becomes one readable message", arguments: [
        (#"{"errors":["2 errors occurred:\n\t* permission denied\n\t* invalid token\n\n"]}"#, "permission denied; invalid token"),
        (#"{"errors":["lease not found"]}"#, "lease not found"),
        (#"{"errors":[]}"#, HTTPURLResponse.localizedString(forStatusCode: 403)),
    ])
    func errorMessages(body: String, expected: String) async {
        let transport = VaultFakeTransport()
        transport.reply("GET", "database/creds/readonly", status: 403, body)
        let client = VaultClient(endpoint: VaultFixtures.endpoint, transport: transport)

        let error = await #expect(throws: VaultRequestError.self) {
            try await client.readCredentials(path: "database/creds/readonly", token: "t0")
        }
        #expect(error?.message == expected)
    }

    @Test("Renewal asks for the original increment and reports what Vault granted")
    func renewsLease() async throws {
        let transport = VaultFakeTransport()
        transport.reply("PUT", "sys/leases/renew", #"{"lease_id":"l1","renewable":true,"lease_duration":42}"#)
        let client = VaultClient(endpoint: VaultFixtures.endpoint, transport: transport)

        let granted = try await client.renewLease(id: "l1", increment: .seconds(3_600), token: "t0")

        #expect(granted == .seconds(42))
        #expect(transport.requests.first?.body == ["lease_id": "l1", "increment": "3600"])
    }

    @Test("Revoking sends the lease id and accepts an empty 204")
    func revokesLease() async throws {
        let transport = VaultFakeTransport()
        transport.reply("PUT", "sys/leases/revoke", status: 204, "")
        let client = VaultClient(endpoint: VaultFixtures.endpoint, transport: transport)

        try await client.revokeLease(id: "l1", token: "t0")

        #expect(transport.requests.first?.body == ["lease_id": "l1"])
    }

    @Test("A token with ttl 0 never expires")
    func lookupSelfTTL() async throws {
        let transport = VaultFakeTransport()
        transport.reply("GET", "auth/token/lookup-self", VaultFixtures.lookupReply(ttl: 0))
        let client = VaultClient(endpoint: VaultFixtures.endpoint, transport: transport)

        let grant = try await client.lookupSelf(token: "root")

        #expect(grant.ttl == nil)
    }

    @Test("An unreachable Vault names the address")
    func unreachable() async {
        let client = VaultClient(endpoint: VaultFixtures.endpoint, transport: VaultFakeTransport())

        await #expect(throws: VaultError.unreachable(
            "https://vault.test:8200",
            URLError(.cannotConnectToHost).localizedDescription
        )) {
            try await client.readCredentials(path: "database/creds/readonly", token: "t0")
        }
    }
}
