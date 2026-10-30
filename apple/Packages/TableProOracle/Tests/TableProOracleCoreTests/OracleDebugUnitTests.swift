import Foundation
@testable import TableProOracleCore
import Testing

struct OracleDebugUnitTests {
    @Test func testMeasuredClassSignaturesMapToUnits() {
        #expect(OracleDebugUnit(jdwpSignature: "L$Oracle/PackageBody/PROBE/PKG_CALC;")
            == OracleDebugUnit(owner: "PROBE", name: "PKG_CALC", kind: .packageBody))
        #expect(OracleDebugUnit(jdwpSignature: "L$Oracle/Package/PROBE/PKG_CALC;")
            == OracleDebugUnit(owner: "PROBE", name: "PKG_CALC", kind: .package))
        #expect(OracleDebugUnit(jdwpSignature: "L$Oracle/Procedure/PROBE/P_WRITE;")
            == OracleDebugUnit(owner: "PROBE", name: "P_WRITE", kind: .procedure))
        #expect(OracleDebugUnit(jdwpSignature: "L$Oracle/Function/PROBE/F_CALC;")
            == OracleDebugUnit(owner: "PROBE", name: "F_CALC", kind: .function))
    }

    @Test func testBlocksBuiltinsAndLocalTypesAreNotUnits() {
        #expect(OracleDebugUnit(jdwpSignature: "L$Oracle/Block/PROBE/B5b7fkkBPUBJ4f33OXgisXQ;") == nil)
        #expect(OracleDebugUnit.isAnonymousBlock(jdwpSignature: "L$Oracle/Block/PROBE/B5b7fkkBPUBJ4f33OXgisXQ;"))
        #expect(OracleDebugUnit(jdwpSignature: "L$Oracle/Builtin/NUMBER;") == nil)
        #expect(OracleDebugUnit(jdwpSignature: "L$Oracle/Function/PROBE/F_CALC/F_CALC/T_NUMS;") == nil)
        #expect(OracleDebugUnit(jdwpSignature: "Ljava/lang/String;") == nil)
    }

    @Test func testUnitsMapBackToClassMatchPatterns() {
        let unit = OracleDebugUnit(owner: "PROBE", name: "PKG_CALC", kind: .packageBody)
        #expect(unit.jdwpClassName == "$Oracle/PackageBody/PROBE/PKG_CALC")
        #expect(unit.jdwpSignature == "L$Oracle/PackageBody/PROBE/PKG_CALC;")
        #expect(OracleDebugUnit(jdwpSignature: unit.jdwpSignature) == unit)
    }

    @Test func testIdentityRoundTripsNamesHoldingSlashesAndPercents() {
        let unit = OracleDebugUnit(owner: "A/B%", name: "x/y%2F", kind: .packageBody)
        #expect(unit.identity == "PACKAGE BODY/A%2FB%25/x%2Fy%252F")
        #expect(OracleDebugUnit(identity: unit.identity) == unit)
        #expect(OracleDebugUnit(identity: "VIEW/PROBE/V") == nil)
    }

    @Test func testEntryIdentityCarriesTheSubprogramAndItsID() {
        let entry = OracleDebugEntry(
            unit: OracleDebugUnit(owner: "PROBE", name: "PKG_CALC", kind: .packageBody),
            subprogram: "ADD_TAX",
            subprogramID: 2
        )
        #expect(entry.identity == "PACKAGE BODY/PROBE/PKG_CALC/ADD_TAX/2")
        #expect(OracleDebugEntry(identity: entry.identity) == entry)
        #expect(entry.isPackaged)
    }

    @Test func testCompileForDebugKeepsSettingsAndQuotesNames() {
        #expect(OracleDebugUnitKind.packageBody.compileForDebugStatement(owner: "PROBE", name: "PKG_CALC")
            == "ALTER PACKAGE \"PROBE\".\"PKG_CALC\" COMPILE BODY PLSQL_OPTIMIZE_LEVEL=1 REUSE SETTINGS")
        #expect(OracleDebugUnitKind.procedure.compileForDebugStatement(owner: "PROBE", name: "P\"Q")
            == "ALTER PROCEDURE \"PROBE\".\"P\"\"Q\" COMPILE PLSQL_OPTIMIZE_LEVEL=1 REUSE SETTINGS")
        #expect(OracleDebugUnitKind.function.compileForDebugStatement(owner: "PROBE", name: "F_CALC")
            == "ALTER FUNCTION \"PROBE\".\"F_CALC\" COMPILE PLSQL_OPTIMIZE_LEVEL=1 REUSE SETTINGS")
    }

    @Test func testDBMSDebugNamespacesAndLibunitTypes() {
        #expect(OracleDebugUnitKind(namespace: 2, libunitType: 11) == .packageBody)
        #expect(OracleDebugUnitKind(namespace: 1, libunitType: 7) == .procedure)
        #expect(OracleDebugUnitKind(namespace: 1, libunitType: 8) == .function)
        #expect(OracleDebugUnitKind(namespace: 1, libunitType: 9) == .package)
        #expect(OracleDebugUnitKind(namespace: 0, libunitType: 0) == nil)
        #expect(OracleDebugUnitKind.packageBody.namespace == 2)
        #expect(OracleDebugUnitKind.function.namespace == 1)
    }

    @Test func testTypeNamesComeFromSignatures() {
        #expect(OracleDebugUnit.typeName(fromJDWPSignature: "L$Oracle/Builtin/NUMBER;") == "NUMBER")
        #expect(OracleDebugUnit.typeName(fromJDWPSignature: "L$Oracle/Function/PROBE/F_CALC/F_CALC/T_REC;") == "T_REC")
    }
}
