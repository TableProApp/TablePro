//
//  CompareSyncSampledColumnsTests.swift
//  TableProTests
//
//  A MongoDB collection's columns are the fields found in a sample of its documents, so a field the
//  source's sample missed reads as one the target holds and the source does not. A structure script
//  written from that would be an `$unset` across every document of the target.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct CompareSyncSampledColumnsTests {
    private func endpoint(_ name: String, _ type: DatabaseType) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: UUID(), database: "shop", schema: nil),
            connectionName: name,
            databaseType: type,
            safeModeLevel: .silent,
            color: .blue
        )
    }

    @Test("An engine whose columns are sampled never generates a structure script, on either side")
    func sampledColumnsGenerateNoScript() {
        #expect(!CompareSyncEngineFamily.canGenerateStructureScript(from: .mongodb, to: .mongodb))
        #expect(!CompareSyncEngineFamily.canGenerateStructureScript(from: .postgresql, to: .mongodb))
        #expect(!CompareSyncEngineFamily.canGenerateStructureScript(from: .mongodb, to: .postgresql))
        #expect(CompareSyncEngineFamily.canGenerateStructureScript(from: .postgresql, to: .postgresql))
    }

    @Test("The refusal names the sampled engine rather than a type mismatch")
    func refusalNamesTheSample() {
        #expect(CompareSyncEngineFamily.structureScriptRefusal(from: .mongodb, to: .mongodb) == String(
            format: String(localized: "%@ lists a collection's fields from a sample of its documents, so structures can be compared but no script is generated."),
            "MongoDB"
        ))
    }

    @Test("A structure compare between two MongoDB databases offers no script to build")
    func compareSessionOffersNoScript() {
        let session = CompareSyncSession(connectionsProvider: { [] })
        session.mode = .structure
        session.source = endpoint("staging", .mongodb)
        session.target = endpoint("production", .mongodb)

        #expect(!session.canGenerateStructureScript)
        #expect(session.crossEngineNotice == CompareSyncEngineFamily.structureScriptRefusal(from: .mongodb, to: .mongodb))
        #expect(!session.canBuildScript)
    }
}
