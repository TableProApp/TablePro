import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct CompareSyncSessionFamilyTests {
    private static let oracleMode = PluginSessionLexicalState(determined: [.plsqlBlocks], enabled: [.plsqlBlocks])
    private static let pgMode = PluginSessionLexicalState(determined: [.plsqlBlocks], enabled: [])

    @Test
    func kingbaseESSyncsStructureWithPostgreSQLInPostgreSQLMode() {
        #expect(CompareSyncEngineFamily.canGenerateStructureScript(
            from: .postgresql, to: .kingbasees, sourceSession: nil, targetSession: Self.pgMode
        ))
        #expect(CompareSyncEngineFamily.canGenerateStructureScript(
            from: .kingbasees, to: .postgresql, sourceSession: Self.pgMode, targetSession: nil
        ))
    }

    @Test
    func anOracleModeServerSyncsStructureOnlyWithAnotherOne() {
        #expect(!CompareSyncEngineFamily.canGenerateStructureScript(
            from: .postgresql, to: .kingbasees, sourceSession: nil, targetSession: Self.oracleMode
        ))
        #expect(!CompareSyncEngineFamily.canGenerateStructureScript(
            from: .kingbasees, to: .kingbasees, sourceSession: Self.pgMode, targetSession: Self.oracleMode
        ))
        #expect(CompareSyncEngineFamily.canGenerateStructureScript(
            from: .kingbasees, to: .kingbasees, sourceSession: Self.oracleMode, targetSession: Self.oracleMode
        ))
        let refusal = CompareSyncEngineFamily.structureScriptRefusal(
            from: .postgresql, to: .kingbasees, sourceSession: nil, targetSession: Self.oracleMode
        )
        #expect(refusal.contains("compatibility mode"))
    }

    @Test
    func postgreSQLStaysUnpairedWithItsOtherVariants() {
        #expect(!CompareSyncEngineFamily.canGenerateStructureScript(from: .postgresql, to: .cockroachdb))
        #expect(!CompareSyncEngineFamily.canGenerateStructureScript(from: .postgresql, to: .pglite))
    }
}
