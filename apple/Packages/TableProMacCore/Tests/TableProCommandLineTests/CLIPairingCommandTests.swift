import Foundation
@testable import TableProCommandLine
import TableProMCP
import TableProMCPTestSupport
import Testing

private func discovered() throws -> MockHttpResponse {
    try rpc(.successResponse(JsonRpcSuccessResponse(id: .number(1), result: .object(["supportedVersions": .array([])]))))
}

private func rejected() throws -> MockHttpResponse {
    let failure = JsonRpcErrorResponse(id: nil, error: JsonRpcError(code: JsonRpcErrorCode.unauthenticated, message: "Unauthenticated"))
    return try rpc(.errorResponse(failure), status: 401)
}

struct CLIStatusTests {
    @Test("Running, serving and paired exits 0 and reports each part")
    func ready() async throws {
        try await withRig { rig in
            await rig.route(["server/discover": try discovered()])
            #expect(await rig.run(["status", "--format", "json"]) == .success)
            #expect(rig.console.output == """
            [
              {"app":"/Applications/TablePro.app","version":"9.8.7","running":true,"mcp_server":true,"paired":true}
            ]

            """)
            let request = try #require(await rig.server.requests.first)
            #expect(request.header("Authorization") == "Bearer tp_stored")
            #expect(rig.log.calls == ["findServer"])
        }
    }

    @Test("A token TablePro no longer accepts exits 3 and stays where it is")
    func rejectedToken() async throws {
        try await withRig { rig in
            await rig.route(["server/discover": try rejected()])
            #expect(await rig.run(["status", "--format", "csv"]) == .refused)
            #expect(rig.console.output.hasSuffix("true,true,false\n"))
            #expect(rig.console.errors.contains("tablepro pair"))
            #expect(rig.tokens.current == "tp_stored")
        }
    }

    @Test("No token exits 3 without asking TablePro")
    func unpaired() async throws {
        try await withRig(token: nil) { rig in
            #expect(await rig.run(["status"]) == .refused)
            #expect(await rig.server.requests.isEmpty)
        }
    }

    @Test("A server that is off exits 3, TablePro not running exits 1, and neither launches it", arguments: [
        (CLIServerProbe.turnedOff, CLIExitCode.refused),
        (.notRunning, .failure),
        (.unreachable("no answer"), .failure)
    ])
    func notServing(probe: CLIServerProbe, expected: CLIExitCode) async throws {
        try await withRig { rig in
            #expect(await rig.run(["status"], probe: probe) == expected)
            #expect(rig.log.calls == ["findServer"])
            #expect(await rig.server.requests.isEmpty)
            #expect(!rig.console.errors.isEmpty)
        }
    }
}

struct CLIUnpairTests {
    @Test("unpair revokes the token at TablePro with an RFC 7009 form, then forgets it")
    func revokes() async throws {
        try await withRig { rig in
            await rig.route([CLIServerClient.revocationPath: plainJson("{}", status: 200)])
            #expect(await rig.run(["unpair"]) == .success)
            let request = try #require(await rig.server.requests.first)
            #expect(request.method == "POST")
            #expect(request.path == "/v1/integrations/revoke")
            #expect(request.header("Content-Type") == "application/x-www-form-urlencoded")
            #expect(request.header("Authorization") == nil)
            #expect(String(data: request.body, encoding: .utf8) == "token=tp_stored")
            #expect(rig.tokens.current == nil)
            #expect(rig.console.output.contains("revoked"))
            #expect(!rig.log.calls.contains("openServer"))
        }
    }

    @Test("A refused revocation still forgets the token and points at Settings")
    func refused() async throws {
        try await withRig { rig in
            await rig.route([CLIServerClient.revocationPath: plainJson("{\"error\":\"unsupported_token_type\"}", status: 400)])
            #expect(await rig.run(["unpair"]) == .failure)
            #expect(rig.tokens.current == nil)
            #expect(rig.console.errors.contains("unsupported_token_type"))
            #expect(rig.console.errors.contains("Settings > MCP"))
        }
    }

    @Test("A revocation TablePro could not save keeps the token, exits 1 and says to try again")
    func notSaved() async throws {
        try await withRig { rig in
            await rig.route([CLIServerClient.revocationPath: plainJson("{\"error\":\"temporarily_unavailable\"}", status: 503)])
            #expect(await rig.run(["unpair"]) == .failure)
            #expect(rig.tokens.current == "tp_stored")
            #expect(rig.console.output.isEmpty)
            #expect(rig.console.errors.contains("did not save the revocation"))
            #expect(rig.console.errors.contains("tablepro unpair again"))
            #expect(rig.console.errors.contains("Settings > MCP"))
        }
    }

    @Test("With TablePro unreachable the token is forgotten here and the user is told it stays listed")
    func unreachable() async throws {
        try await withRig { rig in
            #expect(await rig.run(["unpair"], probe: .notRunning) == .failure)
            #expect(rig.tokens.current == nil)
            #expect(await rig.server.requests.isEmpty)
            #expect(rig.console.errors.contains("stays listed under Settings > MCP"))
            #expect(!rig.log.calls.contains("openServer"))
        }
    }

    @Test("Unpairing a command that is not paired does nothing and exits 0")
    func notPaired() async throws {
        try await withRig(token: nil) { rig in
            #expect(await rig.run(["unpair"]) == .success)
            #expect(rig.console.output == "This command is not paired.\n")
            #expect(rig.log.calls.isEmpty)
        }
    }
}

struct CLIPairTests {
    @Test("pair keeps the new token and revokes the one it replaces")
    func replacesToken() async throws {
        try await withRig { rig in
            await rig.route([CLIServerClient.revocationPath: plainJson("{}", status: 200)])
            #expect(await rig.run(["pair"]) == .success)
            #expect(rig.tokens.current == "tp_paired")
            #expect(rig.log.calls == ["openServer", "pair"])
            let request = try #require(await rig.server.requests.first)
            #expect(String(data: request.body, encoding: .utf8) == "token=tp_stored")
            #expect(!rig.console.errors.contains("previous token"))
            #expect(rig.console.output == "Paired with TablePro.\n")
        }
    }

    @Test("A failed revocation keeps the new pairing and warns about the old token", arguments: [503, 400])
    func revocationFails(status: Int) async throws {
        try await withRig { rig in
            await rig.route([CLIServerClient.revocationPath: plainJson("{}", status: status)])
            #expect(await rig.run(["pair"]) == .success)
            #expect(rig.tokens.current == "tp_paired")
            #expect(rig.console.output == "Paired with TablePro.\n")
            #expect(rig.console.errors == """
            tablepro: approve the tablepro command in TablePro to pair it.
            tablepro: The previous token is still active. Revoke it under Settings > MCP.

            """)
        }
    }

    @Test("A thrown revocation keeps the new pairing and warns about the old token")
    func revocationThrows() async throws {
        try await withRig { rig in
            await rig.server.stop()
            #expect(await rig.run(["pair"]) == .success)
            #expect(rig.tokens.current == "tp_paired")
            #expect(rig.console.output == "Paired with TablePro.\n")
            #expect(rig.console.errors == """
            tablepro: approve the tablepro command in TablePro to pair it.
            tablepro: The previous token is still active. Revoke it under Settings > MCP.

            """)
        }
    }

    @Test("A first pairing revokes nothing")
    func firstPairing() async throws {
        try await withRig(token: nil) { rig in
            #expect(await rig.run(["pair"]) == .success)
            #expect(rig.tokens.current == "tp_paired")
            #expect(await rig.server.requests.isEmpty)
        }
    }
}
