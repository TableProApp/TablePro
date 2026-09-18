@testable import TableProOracleCore
import XCTest

/// A `DBMS_OUTPUT` line can be 32767 bytes and a SQL value on a `MAX_STRING_SIZE=STANDARD` database only 4000, so
/// the driver reads each line as marked pieces and joins them here.
final class OracleServerOutputTests: XCTestCase {
    func testPiecesJoinIntoTheLinesTheyCameFrom() {
        let output = OracleServerOutput.read(
            pieces: ["NHello", "N", "Nfirst half ", "Csecond half", "Nlast"],
            reportedCount: 4,
            cap: 10
        )
        XCTAssertEqual(output, OracleServerOutput(
            lines: ["Hello", "", "first half second half", "last"],
            isTruncated: false
        ))
    }

    func testMoreLinesThanTheCapReportsTruncation() {
        let output = OracleServerOutput.read(pieces: ["Na", "Nb", "Nc"], reportedCount: 4, cap: 3)
        XCTAssertEqual(output, OracleServerOutput(lines: ["a", "b", "c"], isTruncated: true))
    }

    func testAnEmptyBufferReadsAsNoOutput() {
        XCTAssertEqual(OracleServerOutput.read(pieces: [], reportedCount: 0, cap: 10), .empty)
    }

    func testAPieceWithoutAMarkerIsSkipped() {
        let output = OracleServerOutput.read(pieces: [nil, "", "Nkept"], reportedCount: 1, cap: 10)
        XCTAssertEqual(output.lines, ["kept"])
    }

    func testAPieceIsShortEnoughForAStandardVarchar() {
        XCTAssertLessThanOrEqual(1 + OracleServerOutput.pieceLength * 4, 4_000)
    }

    /// Measured on Oracle 23ai: a `DBMS_OUTPUT` package in the session's own schema received the `ENABLE` and
    /// `GET_LINES` calls a bare name made, and the real line was never read.
    func testEveryServerPackageAndTypeIsNamedWithItsOwner() {
        let ownedNames = ["DBMS_OUTPUT", "DBMSOUTPUT_LINESARRAY", "ODCIVARCHAR2LIST"]
        for sql in [OracleServerOutput.enableStatement, OracleServerOutput.drainBlock(maxLines: 10)] {
            for name in ownedNames {
                let occurrences = sql.components(separatedBy: name).count - 1
                let owned = sql.components(separatedBy: "SYS." + name).count - 1
                XCTAssertEqual(occurrences, owned, "\(name) is named without its owner in:\n\(sql)")
            }
        }
    }

    func testTheBindsAppearInTheOrderTheyAreAppended() throws {
        let block = OracleServerOutput.drainBlock(maxLines: 10)
        let lineCount = try XCTUnwrap(block.range(of: ":" + OracleServerOutput.lineCountBindName))
        let pieces = try XCTUnwrap(block.range(of: ":" + OracleServerOutput.piecesBindName))
        XCTAssertLessThan(lineCount.lowerBound, pieces.lowerBound)
    }

    func testTheBlockAsksForOneLineMoreThanTheCap() {
        let block = OracleServerOutput.drainBlock(maxLines: 250)
        XCTAssertTrue(block.contains("l_cap CONSTANT PLS_INTEGER := 250;"))
        XCTAssertTrue(block.contains("l_count INTEGER := l_cap + 1;"))
    }
}
