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
    /// A `CALL` resolves `SYS.DBMS_OUTPUT` at SQL level, where the first component is a schema before it is any object
    /// in the current schema, so a package named `SYS` planted in a schema the session has switched into cannot capture
    /// it. The same name inside a `BEGIN ... END` block resolves through PL/SQL, which reaches that package first and
    /// runs its code with the reader's privileges. Measured on 23ai: the block form was captured across schemas, the
    /// `CALL` form was not.
    static let enableStatement = "CALL SYS.DBMS_OUTPUT.ENABLE(NULL)"

    static let lineCountBindName = "line_count"
    static let pieceCountBindName = "piece_count"
    static let piecesBindName = "pieces"

    /// Reads up to `maxLines` lines in one round trip, returned as a cursor of pieces the caller rejoins.
    ///
    /// Every reference to `DBMS_OUTPUT` is inside an `EXECUTE IMMEDIATE` of a `CALL`, which resolves the name at SQL
    /// level, so the block names no schema object in PL/SQL context and a package named `SYS` in a schema the session
    /// has switched into cannot capture the drain. The block form of the same name resolves through PL/SQL, which
    /// reaches that package first and runs its code with the reader's privileges (measured captured on 23ai).
    /// `GET_LINES` cannot be reached with a `CALL` because binding its collection parameter is not possible over the
    /// wire, so the lines are read one at a time with `GET_LINE`, whose parameters are scalars. `VARCHAR2`,
    /// `PLS_INTEGER`, `INTEGER`, `SUBSTR`, `LENGTH`, `NVL` and `CHR` are built-ins the language resolves through
    /// `STANDARD`, not schema objects, so they are not shadowable (measured on 23ai).
    ///
    /// Each line is split into pieces a SQL `VARCHAR2` can carry, and every piece is written as one fixed-width frame:
    /// a marker (`N` where a line begins, `C` where it continues), the piece's length in three digits, then the piece
    /// padded to the piece length. The frames are equal width, so the cursor reads frame `n` with one `SUBSTR` at a
    /// computed offset rather than scanning for a separator, which keeps the read linear. A separator instead (a
    /// newline, say) needs `REGEXP_SUBSTR` per row, which rescans from the start each time and was measured to take
    /// minutes for a few thousand lines. The cursor cannot read from a PL/SQL collection: a locally declared collection
    /// type is rejected by the `TABLE` operator (PLS-00642), and a `SYS` collection type named in PL/SQL is capturable.
    ///
    /// `GET_LINE` reports the buffer one line at a time and never signals more than was read, so the block asks for one
    /// line past the cap: reaching it re-enables the buffer, which discards the rest, so the next read starts with the
    /// next statement's lines rather than a tail of this one.
    ///
    /// Frames land in a `VARCHAR2` and only spill into the CLOB when it is full, so the CLOB is grown a few dozen times
    /// rather than once per line, which the repeated `||` on a temporary LOB would make quadratic.
    static func drainBlock(maxLines: Int) -> String {
        """
        DECLARE
          l_cap CONSTANT PLS_INTEGER := \(maxLines);
          l_piece_length CONSTANT PLS_INTEGER := \(pieceLength);
          l_frame_width CONSTANT PLS_INTEGER := \(frameWidth);
          l_chunk_limit CONSTANT PLS_INTEGER := \(chunkLimit);
          l_line VARCHAR2(32767);
          l_status INTEGER := 0;
          l_count PLS_INTEGER := 0;
          l_pieces PLS_INTEGER := 0;
          l_offset PLS_INTEGER;
          l_piece VARCHAR2(1000);
          l_buffer CLOB;
          l_chunk VARCHAR2(32767);
        BEGIN
          <<each_line>>
          LOOP
            EXECUTE IMMEDIATE 'CALL SYS.DBMS_OUTPUT.GET_LINE(:1, :2)' USING OUT l_line, OUT l_status;
            EXIT each_line WHEN l_status <> 0;
            l_count := l_count + 1;
            IF l_count > l_cap THEN
              EXECUTE IMMEDIATE 'CALL SYS.DBMS_OUTPUT.DISABLE()';
              EXECUTE IMMEDIATE 'CALL SYS.DBMS_OUTPUT.ENABLE(NULL)';
              EXIT each_line;
            END IF;
            l_offset := 1;
            LOOP
              l_piece := SUBSTR(l_line, l_offset, l_piece_length);
              IF NVL(LENGTH(l_chunk), 0) + l_frame_width > l_chunk_limit THEN
                l_buffer := l_buffer || l_chunk;
                l_chunk := NULL;
              END IF;
              l_chunk := l_chunk
                || (CASE WHEN l_offset = 1 THEN 'N' ELSE 'C' END)
                || LPAD(TO_CHAR(NVL(LENGTH(l_piece), 0)), 3, '0')
                || RPAD(NVL(l_piece, ' '), l_piece_length, ' ');
              l_pieces := l_pieces + 1;
              l_offset := l_offset + l_piece_length;
              EXIT WHEN l_offset > NVL(LENGTH(l_line), 0);
            END LOOP;
          END LOOP;
          IF l_chunk IS NOT NULL THEN
            l_buffer := l_buffer || l_chunk;
          END IF;
          :\(lineCountBindName) := l_count;
          :\(pieceCountBindName) := l_pieces;
          OPEN :\(piecesBindName) FOR
            SELECT TO_CHAR(SUBSTR(l_buffer, (LEVEL - 1) * l_frame_width + 1, l_frame_width))
            FROM SYS.DUAL
            CONNECT BY LEVEL <= l_pieces;
        END;
        """
    }

    /// Characters of the line one piece carries. Kept so a frame (a marker, a three-digit length and the piece) stays
    /// under the 4000 bytes a SQL `VARCHAR2` holds even at four bytes a character, the widest any Oracle character set
    /// uses: `990 * 4` is `3960`.
    static let pieceLength = 986

    /// The fixed width of a frame: a one-character marker, a three-digit length, then the piece.
    static let frameWidth = pieceLength + 4

    /// The number of leading characters of a frame before its piece: the marker and the three-digit length.
    static let frameHeader = 4

    /// The `VARCHAR2` frames accumulate in before they spill to the CLOB, below the 32767 a `VARCHAR2` holds with room
    /// for one more frame.
    static let chunkLimit = 32_767 - frameWidth

    private static let newLineMarker: Character = "N"

    /// Rejoins the fixed-width frames the cursor returned, each marked `N` where a line begins and `C` where it
    /// continues, with the piece's real length in the three characters after the marker so the padding is dropped.
    ///
    /// `reportedCount` is the number of lines the block read, which is one past the cap when the buffer held more, so a
    /// truncated read is told apart from one that held exactly `cap`.
    static func read(pieces: [String?], reportedCount: Int, cap: Int) -> OracleServerOutput {
        var lines: [String] = []
        for frame in pieces {
            guard let frame, frame.count >= frameHeader, let marker = frame.first else { continue }
            let header = Array(frame.prefix(frameHeader))
            guard let length = Int(String(header[1...])) else { continue }
            let body = frame.dropFirst(frameHeader)
            let text = String(body.prefix(length))
            if marker == newLineMarker || lines.isEmpty {
                lines.append(text)
            } else {
                lines[lines.count - 1] += text
            }
        }
        return OracleServerOutput(lines: Array(lines.prefix(cap)), isTruncated: reportedCount > cap)
    }
}
