import Foundation
@testable import TableProOracleCore
import Testing

/// A `DBMS_OUTPUT` line can be 32767 bytes and a SQL value on a `MAX_STRING_SIZE=STANDARD` database only 4000, so the
/// driver reads each line as fixed-width frames (a marker, the piece length, the padded piece) and rejoins them here.
struct OracleServerOutputTests {
    private func frame(_ marker: Character, _ content: String) -> String {
        let length = String(format: "%03d", content.count)
        let padded = content.padding(toLength: OracleServerOutput.pieceLength, withPad: " ", startingAt: 0)
        return "\(marker)\(length)\(padded)"
    }

    @Test func testFramesJoinIntoTheLinesTheyCameFrom() {
        let output = OracleServerOutput.read(
            pieces: [
                frame("N", "Hello"),
                frame("N", ""),
                frame("N", "first half "),
                frame("C", "second half"),
                frame("N", "last")
            ],
            reportedCount: 4,
            cap: 10
        )
        #expect(output == OracleServerOutput(
            lines: ["Hello", "", "first half second half", "last"],
            isTruncated: false
        ))
    }

    @Test func testTrailingSpacesInAPieceSurviveThePadding() {
        let output = OracleServerOutput.read(pieces: [frame("N", "value   ")], reportedCount: 1, cap: 10)
        #expect(output.lines == ["value   "])
    }

    @Test func testMoreLinesThanTheCapReportsTruncation() {
        let output = OracleServerOutput.read(
            pieces: [frame("N", "a"), frame("N", "b"), frame("N", "c")],
            reportedCount: 4,
            cap: 3
        )
        #expect(output == OracleServerOutput(lines: ["a", "b", "c"], isTruncated: true))
    }

    @Test func testAnEmptyBufferReadsAsNoOutput() {
        #expect(OracleServerOutput.read(pieces: [], reportedCount: 0, cap: 10) == .empty)
    }

    @Test func testAFrameWithoutAHeaderIsSkipped() {
        let output = OracleServerOutput.read(pieces: [nil, "", frame("N", "kept")], reportedCount: 1, cap: 10)
        #expect(output.lines == ["kept"])
    }

    @Test func testAFrameIsShortEnoughForAStandardVarchar() {
        #expect(OracleServerOutput.frameWidth * 4 <= 4_000)
    }

    /// The drain reaches `DBMS_OUTPUT` only through a `CALL` inside `EXECUTE IMMEDIATE`, so its name resolves at SQL
    /// level and a package named `SYS` in a schema the session switched into cannot capture it. Measured on 23ai: the
    /// `BEGIN SYS.DBMS_OUTPUT... END;` form was captured across schemas, the `CALL` form was not.
    @Test func testDbmsOutputIsReachedOnlyThroughASqlLevelCall() {
        for sql in [OracleServerOutput.enableStatement, OracleServerOutput.drainBlock(maxLines: 10)] {
            let mentions = sql.components(separatedBy: "DBMS_OUTPUT").count - 1
            let throughCall = sql.components(separatedBy: "CALL SYS.DBMS_OUTPUT").count - 1
            #expect(mentions == throughCall, "DBMS_OUTPUT is named outside a CALL in:\n\(sql)")
        }
    }

    /// The drain declares no variable of a `SYS` collection type: naming one in PL/SQL resolves it through a package
    /// named `SYS` in the current schema, and a locally declared collection type cannot feed the `TABLE` operator, so
    /// the block reads its pieces back out of a CLOB at SQL level instead.
    @Test func testTheDrainNamesNoSysCollectionType() {
        let block = OracleServerOutput.drainBlock(maxLines: 10)
        for type in ["DBMSOUTPUT_LINESARRAY", "ODCIVARCHAR2LIST"] {
            #expect(!block.contains(type), "\(type) is named in the drain block:\n\(block)")
        }
    }

    @Test func testEnableIsASqlLevelCall() {
        #expect(OracleServerOutput.enableStatement == "CALL SYS.DBMS_OUTPUT.ENABLE(NULL)")
    }

    @Test func testTheBindsAppearInTheOrderTheyAreAppended() throws {
        let block = OracleServerOutput.drainBlock(maxLines: 10)
        let lineCount = try #require(block.range(of: ":" + OracleServerOutput.lineCountBindName))
        let pieceCount = try #require(block.range(of: ":" + OracleServerOutput.pieceCountBindName))
        let pieces = try #require(block.range(of: ":" + OracleServerOutput.piecesBindName))
        #expect(lineCount.lowerBound < pieceCount.lowerBound)
        #expect(pieceCount.lowerBound < pieces.lowerBound)
    }

    @Test func testTheBlockStopsOneLinePastTheCap() {
        let block = OracleServerOutput.drainBlock(maxLines: 250)
        #expect(block.contains("l_cap CONSTANT PLS_INTEGER := 250;"))
        #expect(block.contains("IF l_count > l_cap THEN"))
    }
}
