import Foundation

/// The lines a session wrote with `DBMS_OUTPUT` since they were last read.
///
/// Oracle buffers `DBMS_OUTPUT.PUT_LINE` on the server once the session has called `DBMS_OUTPUT.ENABLE`, and hands the
/// lines back only when asked with `GET_LINES`, which consumes them. SQL*Plus's `SET SERVEROUTPUT ON` is the same pair of
/// calls.
public struct OracleServerOutput: Sendable, Equatable {
    public let lines: [String]

    /// Whether the buffer held more than was read. The rest is discarded, so the next read starts clean rather than
    /// with lines that belong to an earlier statement.
    public let isTruncated: Bool

    public static let empty = OracleServerOutput(lines: [], isTruncated: false)

    public init(lines: [String], isTruncated: Bool) {
        self.lines = lines
        self.isTruncated = isTruncated
    }

    /// `NULL` for no limit on the server's buffer, as `SET SERVEROUTPUT ON` asks for.
    ///
    /// Every package and type is named with its owner. A bare `DBMS_OUTPUT` resolves to an object of that name in the
    /// session's current schema before the public synonym, so anyone who can create one there would have it run with
    /// the reader's privileges after every statement.
    static let enableStatement = "BEGIN SYS.DBMS_OUTPUT.ENABLE(NULL); END;"

    static let lineCountBindName = "line_count"
    static let piecesBindName = "pieces"

    /// Reads up to `maxLines` lines in one round trip, split into pieces a SQL `VARCHAR2` can carry.
    ///
    /// Asks for one line more than the cap, and discards the rest of the buffer when there was more, so the next read
    /// starts with the next statement's lines.
    static func drainBlock(maxLines: Int) -> String {
        """
        DECLARE
          l_lines SYS.DBMSOUTPUT_LINESARRAY;
          l_pieces SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST();
          l_cap CONSTANT PLS_INTEGER := \(maxLines);
          l_piece_length CONSTANT PLS_INTEGER := \(pieceLength);
          l_count INTEGER := l_cap + 1;
          l_line VARCHAR2(32767);
          l_offset PLS_INTEGER;
        BEGIN
          SYS.DBMS_OUTPUT.GET_LINES(l_lines, l_count);
          IF l_count > l_cap THEN
            SYS.DBMS_OUTPUT.DISABLE;
            SYS.DBMS_OUTPUT.ENABLE(NULL);
          END IF;
          <<each_line>>
          FOR i IN 1 .. LEAST(l_count, l_cap) LOOP
            l_line := l_lines(i);
            l_offset := 1;
            LOOP
              IF l_pieces.COUNT = l_pieces.LIMIT THEN
                l_count := l_cap + 1;
                EXIT each_line;
              END IF;
              l_pieces.EXTEND;
              l_pieces(l_pieces.COUNT) := CASE WHEN l_offset = 1 THEN 'N' ELSE 'C' END
                || SUBSTR(l_line, l_offset, l_piece_length);
              l_offset := l_offset + l_piece_length;
              EXIT WHEN l_offset > NVL(LENGTH(l_line), 0);
            END LOOP;
          END LOOP;
          :\(lineCountBindName) := l_count;
          OPEN :\(piecesBindName) FOR SELECT COLUMN_VALUE FROM TABLE(l_pieces);
        END;
        """
    }

    /// Characters per piece a line is returned in. With the one-character marker in front, a piece stays under the 4000
    /// bytes a SQL `VARCHAR2` holds even at four bytes a character, the widest any Oracle character set uses.
    static let pieceLength = 999

    private static let newLineMarker: Character = "N"

    /// Joins the pieces one `GET_LINES` call came back as, each marked `N` where a line starts and `C` where it
    /// continues.
    ///
    /// The call is asked for one line more than `cap`, which is how a buffer holding more than `cap` is told apart
    /// from one holding exactly `cap`.
    static func read(pieces: [String?], reportedCount: Int, cap: Int) -> OracleServerOutput {
        var lines: [String] = []
        for piece in pieces {
            guard let piece, let marker = piece.first else { continue }
            let text = String(piece.dropFirst())
            if marker == newLineMarker || lines.isEmpty {
                lines.append(text)
            } else {
                lines[lines.count - 1] += text
            }
        }
        return OracleServerOutput(lines: Array(lines.prefix(cap)), isTruncated: reportedCount > cap)
    }
}
