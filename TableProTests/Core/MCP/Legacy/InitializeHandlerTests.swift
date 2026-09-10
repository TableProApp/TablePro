import Foundation
@testable import TablePro
import Testing

@Suite("Legacy initialize handler")
struct LegacyInitializeHandlerTests {
    @Test("The handler answers initialize for legacy clients only, and needs no scope")
    func handlerIdentity() {
        #expect(InitializeHandler.method == "initialize")
        #expect(InitializeHandler.requiredScopes.isEmpty)
        #expect(InitializeHandler.isAvailableToLegacyClients)
        #expect(!InitializeHandler.isAvailableToModernClients)
    }

    @Test("Every legacy protocol version is echoed back exactly as requested")
    func negotiationEchoesEachLegacyVersion() throws {
        for version in MCPProtocolVersion.legacy {
            let negotiated = try InitializeHandler.negotiate(requestedVersion: version.rawValue)
            #expect(negotiated == version)
            #expect(negotiated.era == .legacy)
        }
    }

    @Test("Initialize rejects an unsupported protocol version instead of downgrading")
    func initializeRejectsUnsupportedProtocolVersion() {
        let error = #expect(throws: MCPProtocolError.self) {
            _ = try InitializeHandler.negotiate(requestedVersion: "1999-01-01")
        }

        #expect(error?.code == JsonRpcErrorCode.unsupportedProtocolVersion)
        #expect(error?.httpStatus == .badRequest)
        #expect(error?.data?["requested"]?.stringValue == "1999-01-01")
        let supported = error?.data?["supported"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(supported == MCPProtocolVersion.supportedRawValues)
    }

    @Test("A version newer than anything this server knows is refused, never downgraded")
    func futureVersionIsRefused() {
        let error = #expect(throws: MCPProtocolError.self) {
            _ = try InitializeHandler.negotiate(requestedVersion: "2099-01-01")
        }

        #expect(error?.code == JsonRpcErrorCode.unsupportedProtocolVersion)
        #expect(error?.data?["requested"]?.stringValue == "2099-01-01")
    }

    @Test("2025-03-26 is not supported and is refused")
    func theRetiredMarch2025VersionIsRefused() {
        let error = #expect(throws: MCPProtocolError.self) {
            _ = try InitializeHandler.negotiate(requestedVersion: "2025-03-26")
        }

        #expect(error?.code == JsonRpcErrorCode.unsupportedProtocolVersion)
        #expect(!MCPProtocolVersion("2025-03-26").isSupported)
        #expect(!MCPProtocolVersion.supportedRawValues.contains("2025-03-26"))
    }

    @Test("A missing or empty protocol version is refused rather than assumed")
    func missingVersionIsRefused() {
        for requested in [nil, ""] as [String?] {
            let error = #expect(throws: MCPProtocolError.self) {
                _ = try InitializeHandler.negotiate(requestedVersion: requested)
            }
            #expect(error?.code == JsonRpcErrorCode.unsupportedProtocolVersion)
            #expect(error?.data?["requested"] == nil)
        }
    }

    @Test("The modern version is refused on the legacy handshake, which does not exist for it")
    func modernVersionIsRefusedOnTheHandshake() {
        let error = #expect(throws: MCPProtocolError.self) {
            _ = try InitializeHandler.negotiate(requestedVersion: MCPProtocolVersion.latest.rawValue)
        }

        #expect(error?.code == JsonRpcErrorCode.unsupportedProtocolVersion)
    }

    @Test("Handling initialize returns the negotiated version, capabilities, serverInfo and instructions")
    func handleReturnsTheHandshakePayload() async throws {
        let meta = try MCPLegacyTestSupport.legacyMeta()
        let (context, _) = MCPLegacyTestSupport.context(meta: meta)
        let params = MCPLegacyTestSupport.initializeParams(version: MCPProtocolVersion.v20250618.rawValue)

        let result = try await InitializeHandler().handle(params: params, context: context)

        #expect(result.kind == .complete)
        #expect(result.payload["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(result.payload["serverInfo"]?["name"]?.stringValue == "tablepro")
        #expect(result.payload["capabilities"] != nil)
        #expect(result.payload["instructions"]?.stringValue?.isEmpty == false)
    }

    @Test("Handling initialize with an unsupported version throws rather than answering")
    func handleRefusesAnUnsupportedVersion() async throws {
        let meta = try MCPLegacyTestSupport.legacyMeta()
        let (context, _) = MCPLegacyTestSupport.context(meta: meta)
        let params = MCPLegacyTestSupport.initializeParams(version: "2025-03-26")

        let error = await #expect(throws: MCPProtocolError.self) {
            _ = try await InitializeHandler().handle(params: params, context: context)
        }

        #expect(error?.code == JsonRpcErrorCode.unsupportedProtocolVersion)
    }

    @Test("The legacy initialize result keeps its legacy wire shape")
    func theLegacyResultKeepsItsLegacyShape() {
        let result = InitializeHandler.result(protocolVersion: .v20251125)

        let encoded = result.asJsonValue(era: .legacy, serverInfo: MCPMethodRegistry.serverInfo)

        #expect(encoded["protocolVersion"]?.stringValue == "2025-11-25")
        #expect(encoded["serverInfo"]?["name"]?.stringValue == "tablepro")
        #expect(encoded["capabilities"] != nil)
        #expect(encoded["resultType"] == nil)
        #expect(encoded["ttlMs"] == nil)
        #expect(encoded["cacheScope"] == nil)
        #expect(encoded["_meta"] == nil)
    }

    @Test("The legacy capabilities object carries no extensions field")
    func legacyCapabilitiesCarryNoExtensions() {
        let encoded = InitializeHandler.result(protocolVersion: .v20251125)
            .asJsonValue(era: .legacy, serverInfo: MCPMethodRegistry.serverInfo)

        #expect(encoded["capabilities"]?["extensions"] == nil)
        #expect(MCPMethodRegistry.capabilities().asJsonValue(era: .modern)["extensions"] != nil)
    }

    @Test("Logging is advertised in neither era")
    func loggingIsNeverAdvertised() {
        let legacy = MCPMethodRegistry.capabilities().asJsonValue(era: .legacy)
        let modern = MCPMethodRegistry.capabilities().asJsonValue(era: .modern)

        #expect(legacy["logging"] == nil)
        #expect(modern["logging"] == nil)
    }

    @Test("Legacy capabilities report tools, resources, prompts and completions")
    func legacyCapabilitiesReportTheServerSurface() {
        let capabilities = MCPMethodRegistry.capabilities().asJsonValue(era: .legacy)

        #expect(capabilities["tools"] != nil)
        #expect(capabilities["resources"] != nil)
        #expect(capabilities["prompts"] != nil)
        #expect(capabilities["completions"] != nil)
    }

    @Test("Legacy clients are told resource subscriptions are unavailable")
    func legacyClientsGetNoResourceSubscriptions() {
        let capabilities = MCPMethodRegistry.capabilities().asJsonValue(era: .legacy)
        let modern = MCPMethodRegistry.capabilities().asJsonValue(era: .modern)

        #expect(capabilities["resources"]?["subscribe"]?.boolValue == false)
        #expect(modern["resources"]?["subscribe"]?.boolValue == true)
    }

    @Test("The initialize result carries no cache hint")
    func theResultIsNotCacheable() {
        #expect(InitializeHandler.result(protocolVersion: .v20251125).cacheHint == nil)
    }

    @Test("The modern envelope fields the legacy shape omits are added only for the modern era")
    func modernEnvelopeIsAddedOnlyForModernClients() {
        let encoded = InitializeHandler.result(protocolVersion: .v20251125)
            .asJsonValue(era: .modern, serverInfo: MCPMethodRegistry.serverInfo)

        #expect(encoded["resultType"]?.stringValue == "complete")
        #expect(encoded["_meta"]?[MCPMetaKeys.serverInfo]?["name"]?.stringValue == "tablepro")
    }
}
