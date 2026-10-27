import Foundation
import os
@testable import TableProOracleCore
import Testing

struct OracleDebugOverloadAmbiguityTests {
    private let package = OracleDebugUnit(owner: "PROBE", name: "PKG_OVER", kind: .packageBody)

    private func overload(
        _ id: Int,
        _ parameters: [OracleDebugParameter],
        returns result: String? = nil,
        named subprogram: String = "P"
    ) -> OracleDebugEntryPoint {
        OracleDebugEntryPoint(
            entry: OracleDebugEntry(unit: package, subprogram: subprogram, subprogramID: id),
            overload: String(id),
            parameters: parameters,
            result: result.map { OracleDebugParameter(name: "", position: 0, dataType: $0, mode: .output, hasDefault: false) }
        )
    }

    private func parameter(_ name: String, _ type: String, defaulted: Bool, mode: OracleDebugParameter.Mode = .input) -> OracleDebugParameter {
        OracleDebugParameter(name: name, position: 1, dataType: type, mode: mode, hasDefault: defaulted)
    }

    // p(x NUMBER DEFAULT 1) and p(x VARCHAR2 DEFAULT 'a'): `p()` matches both (PLS-00307), so X needs a value.
    @Test func testLeavingTheOnlyDistinguishingParameterAtItsDefaultNeedsAValue() {
        let number = overload(1, [parameter("X", "NUMBER", defaulted: true)])
        let text = overload(2, [parameter("X", "VARCHAR2", defaulted: true)])
        let both = [number, text]
        #expect(OracleDebugStatements.ambiguity(of: number, arguments: ["X": .defaultValue], overloads: both) == .needsValue(["X"]))
        #expect(OracleDebugStatements.ambiguity(of: text, arguments: [:], overloads: both) == .needsValue(["X"]))
        #expect(OracleDebugStatements.ambiguity(of: number, arguments: ["X": .text("5")], overloads: both) == nil)
        #expect(OracleDebugStatements.ambiguity(of: number, arguments: ["X": .null], overloads: both) == nil)
    }

    // p(a NUMBER) and p(a NUMBER, b VARCHAR2 DEFAULT 'x'): with B left out the second is `p(a => 1)`, which the first
    // matches too; the first can never be called unambiguously.
    @Test func testAnOverloadWhoseCallTheOtherAlwaysMatchesIsUnresolvable() {
        let short = overload(1, [parameter("A", "NUMBER", defaulted: false)])
        let long = overload(2, [parameter("A", "NUMBER", defaulted: false), parameter("B", "VARCHAR2", defaulted: true)])
        let both = [short, long]
        #expect(OracleDebugStatements.ambiguity(of: long, arguments: ["A": .text("1")], overloads: both) == .needsValue(["B"]))
        #expect(OracleDebugStatements.ambiguity(of: long, arguments: ["A": .text("1"), "B": .text("y")], overloads: both) == nil)
        #expect(OracleDebugStatements.ambiguity(of: short, arguments: ["A": .text("1")], overloads: both) == .unresolvable)
    }

    @Test func testOverloadsTheCallCannotMatchAreNotAmbiguous() {
        let number = overload(1, [parameter("X", "NUMBER", defaulted: true)])
        let needsZ = overload(2, [parameter("X", "VARCHAR2", defaulted: true), parameter("Z", "DATE", defaulted: false)])
        let function = overload(3, [parameter("X", "VARCHAR2", defaulted: true)], returns: "NUMBER")
        let otherName = overload(4, [parameter("X", "VARCHAR2", defaulted: true)], named: "Q")
        let renamed = overload(5, [parameter("Y", "VARCHAR2", defaulted: true), parameter("W", "NUMBER", defaulted: false)])
        let all = [number, needsZ, function, otherName, renamed]
        #expect(OracleDebugStatements.ambiguity(of: number, arguments: [:], overloads: all) == nil)
        #expect(OracleDebugStatements.ambiguity(of: number, arguments: [:], overloads: [number]) == nil)
        #expect(OracleDebugStatements.ambiguity(of: number, arguments: [:], overloads: []) == nil)
    }

    // An OUT parameter is always passed, so it tells overloads apart by its declaration like any passed one.
    @Test func testAPassedOutParameterOfAnotherTypeDistinguishesTheCall() {
        let numberOut = overload(1, [parameter("R", "NUMBER", defaulted: false, mode: .output), parameter("X", "NUMBER", defaulted: true)])
        let textOut = overload(2, [parameter("R", "VARCHAR2", defaulted: false, mode: .output), parameter("X", "VARCHAR2", defaulted: true)])
        #expect(OracleDebugStatements.ambiguity(of: numberOut, arguments: [:], overloads: [numberOut, textOut]) == nil)
    }

    @Test func testTheLauncherRefusesAnAmbiguousCallBeforeAnySessionOpens() async {
        let number = overload(1, [parameter("X", "NUMBER", defaulted: true)])
        let text = overload(2, [parameter("X", "VARCHAR2", defaulted: true)])
        let opened = OSAllocatedUnfairLock(initialState: 0)
        let launch = OracleDebugLaunch(
            entryPoint: number,
            arguments: ["X": .defaultValue],
            breakpoints: [],
            preference: .dbmsDebug,
            debuggerHost: "127.0.0.1",
            ports: 47_300...47_399,
            databaseHost: "127.0.0.1",
            databasePort: 1_521,
            overloads: [number, text]
        )
        await #expect(throws: OracleDebugError.ambiguousDefaults(subprogram: "P", parameters: ["X"])) {
            _ = try await OracleDebugLauncher.launch(launch) {
                opened.withLock { $0 += 1 }
                return OracleCoreConnection(options: OracleConnectionOptions(host: "127.0.0.1", user: "probe", password: "x"))
            }
        }
        #expect(opened.withLock { $0 } == 0)
    }
}
