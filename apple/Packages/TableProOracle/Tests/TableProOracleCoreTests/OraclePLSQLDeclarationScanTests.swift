import Foundation
@testable import TableProOracleCore
import Testing

struct OraclePLSQLDeclarationScanTests {
    // PROBE.PKG_CALC's body exactly as ALL_SOURCE returned it in the measurements.
    private let packageBody = """
        package body pkg_calc as
          g_rate number := 0.1;
          function add_tax(p_amount number) return number is
            l_tax number;
          begin
            l_tax := p_amount * g_rate;
            return p_amount + l_tax;
          end add_tax;
          procedure run(p_n pls_integer) is
            l_total number := 0;
            l_name  varchar2(30) := 'probe';
          begin
            for i in 1 .. p_n loop
              l_total := l_total + add_tax(i);
            end loop;
            dbms_output.put_line(l_name || ' total=' || l_total);
          end run;
          function add_tax(p_amount number, p_rate number) return number is
          begin
            return p_amount + p_amount * p_rate;
          end add_tax;
        end pkg_calc;
        """

    @Test func testSubprogramsAndTheirLineRanges() {
        let scan = OraclePLSQLDeclarationScan(source: packageBody)
        let subprograms = scan.subprograms.map { "\($0.name) \($0.headerLine)-\($0.endLine ?? 0)" }
        #expect(subprograms == ["ADD_TAX 3-8", "RUN 9-17", "ADD_TAX 18-21"])
        #expect(scan.headerLines(ofSubprogramNamed: "ADD_TAX") == [3, 18])
        #expect(scan.headerLines(ofSubprogramNamed: "RUN") == [9])
    }

    @Test func testCandidatesFollowTheFrameLine() {
        let scan = OraclePLSQLDeclarationScan(source: packageBody)
        #expect(scan.candidates(atLine: 6).map(\.name) == ["P_AMOUNT", "L_TAX"])
        #expect(scan.candidates(atLine: 6).map(\.kind) == [.parameter, .variable])
        #expect(scan.candidates(atLine: 14).map(\.name) == ["P_N", "L_TOTAL", "L_NAME", "I"])
        #expect(scan.candidates(atLine: 9).map(\.name) == ["P_N", "L_TOTAL", "L_NAME"])
        #expect(scan.candidates(atLine: 20).map(\.name) == ["P_AMOUNT", "P_RATE"])
        #expect(scan.candidates(atLine: 11).first { $0.name == "L_NAME" }?.typeText == "VARCHAR2(30)")
        #expect(scan.packageVariables.map(\.name) == ["G_RATE"])
    }

    @Test func testTypesCursorsExceptionsAndConstantsAreTold() {
        let scan = OraclePLSQLDeclarationScan(source: """
            function f_calc(p_a number, p_b in out nocopy varchar2 default 'x') return number is
              type t_rec is record (a number, b varchar2(10));
              cursor c_rows is select 1 from dual;
              e_bad exception;
              pragma exception_init(e_bad, -20001);
              c_limit constant pls_integer := 10;
              l_rec t_rec;
            begin
              return p_a * 2;
            end f_calc;
            """)
        let names = scan.candidates(atLine: 9).map(\.name)
        #expect(names == ["P_A", "P_B", "C_LIMIT", "L_REC"])
        #expect(scan.candidates(atLine: 9).first { $0.name == "C_LIMIT" }?.kind == .constant)
        #expect(scan.candidates(atLine: 9).first { $0.name == "P_B" }?.typeText == "VARCHAR2")
    }

    @Test func testCommentsStringsAndQuotedNamesDoNotConfuseTheScan() {
        let scan = OraclePLSQLDeclarationScan(source: """
            procedure p is
              -- procedure fake is begin end;
              /* function g return number is begin return 1; end; */
              l_text varchar2(100) := q'[it's begin; end]';
              "Mixed Case" number;
            begin
              l_text := 'end; begin';
              declare
                l_inner number;
              begin
                null;
              end;
              case when l_text is null then null; else null; end case;
            end p;
            """)
        #expect(scan.subprograms.map(\.name) == ["P"])
        #expect(scan.subprograms.first?.endLine == 14)
        #expect(scan.candidates(atLine: 7).map(\.name) == ["L_TEXT", "Mixed Case", "L_INNER"])
    }

    // A quoted name keeps its case and its dots and spaces; GET_VALUE gets it quoted, the Variables list shows it bare.
    @Test func testAQuotedNameIsLookedUpQuotedAndShownBare() {
        let scan = OraclePLSQLDeclarationScan(source: """
            package body pkg_quoted as
              "g.Rate" number := 0.2;
              procedure run("p.in" number) is
                "a.b" number := 7;
                "lower" number;
                "with space" varchar2(10);
                l_plain number;
              begin
                for "i.x" in 1 .. 2 loop
                  null;
                end loop;
              end run;
            end pkg_quoted;
            """)
        let candidates = scan.candidates(atLine: 10)
        #expect(candidates.map(\.name) == ["p.in", "a.b", "lower", "with space", "L_PLAIN", "i.x"])
        #expect(candidates.map(\.lookupName) == ["\"p.in\"", "\"a.b\"", "\"lower\"", "\"with space\"", "L_PLAIN", "\"i.x\""])
        #expect(scan.packageVariables.map(\.name) == ["g.Rate"])
        #expect(scan.packageVariables.map(\.lookupName) == ["\"g.Rate\""])
    }

    // A specification's forward declarations are not definitions, and their parameters are nobody's locals.
    @Test func testASpecificationListsOnlyItsVariables() {
        let scan = OraclePLSQLDeclarationScan(source: """
            package pkg_calc as
              g_spec_count pls_integer := 0;
              function add_tax(p_amount number) return number;
              procedure run(p_n pls_integer);
            end pkg_calc;
            """)
        #expect(scan.packageVariables.map(\.name) == ["G_SPEC_COUNT"])
        #expect(scan.declarations.allSatisfy { $0.kind != .parameter })
        #expect(scan.headerLines(ofSubprogramNamed: "RUN").isEmpty)
    }
}
