import Foundation

// What a debug block hands back: fields written as `<length>:<text>`, or `~` for NULL, read through a cursor of
// pieces. Out binds cap a VARCHAR2 at 4000 bytes, and a SQL VARCHAR2 over 4000 bytes fails the fetch with ORA-00910
// (OracleServerOutput), so the block gathers the fields into a CLOB and the cursor reads it 990 characters at a time.
public enum OracleDebugPayload {
    public static let cursorBindName = "rows"
    static let pieceLength = 990
    // A field longer than this is cut, so `length:text` stays inside one VARCHAR2(32767) at four bytes a character.
    public static let fieldLimit = 8_000

    public enum ParseError: Error, Sendable, Equatable {
        case malformed(offset: Int)
    }

    public static let declarations = """
          l_out CLOB;
          l_chunk VARCHAR2(32767);
          PROCEDURE put(p VARCHAR2) IS
            l_piece VARCHAR2(32767);
          BEGIN
            IF p IS NULL THEN
              l_piece := '~';
            ELSE
              l_piece := LENGTH(SUBSTR(p, 1, \(fieldLimit))) || ':' || SUBSTR(p, 1, \(fieldLimit));
            END IF;
            IF NVL(LENGTHB(l_chunk), 0) + LENGTHB(l_piece) > 32000 THEN
              l_out := l_out || l_chunk;
              l_chunk := NULL;
            END IF;
            l_chunk := l_chunk || l_piece;
          END;
        """

    public static let openCursor = """
          IF l_chunk IS NOT NULL THEN
            l_out := l_out || l_chunk;
          END IF;
          OPEN :\(cursorBindName) FOR
            SELECT TO_CHAR(SUBSTR(l_out, (LEVEL - 1) * \(pieceLength) + 1, \(pieceLength)))
            FROM SYS.DUAL
            CONNECT BY LEVEL <= GREATEST(CEIL(NVL(LENGTH(l_out), 0) / \(pieceLength)), 1);
        """

    public static func join(pieces: [String?]) -> String {
        pieces.map { $0 ?? "" }.joined()
    }

    // Lengths count characters as Oracle's LENGTH does in AL32UTF8, one per Unicode scalar.
    public static func parse(_ text: String) throws -> [String?] {
        let scalars = Array(text.unicodeScalars)
        var fields: [String?] = []
        var position = 0
        while position < scalars.count {
            if scalars[position] == "~" {
                fields.append(nil)
                position += 1
                continue
            }
            var length = 0
            var digits = 0
            // A field never exceeds `fieldLimit`, so more than nine digits is not a length this side wrote.
            while position < scalars.count, (48...57).contains(scalars[position].value) {
                guard digits < 9 else { throw ParseError.malformed(offset: position) }
                length = length * 10 + Int(scalars[position].value - 48)
                digits += 1
                position += 1
            }
            guard digits > 0, position < scalars.count, scalars[position] == ":" else {
                throw ParseError.malformed(offset: position)
            }
            position += 1
            guard length <= scalars.count - position else { throw ParseError.malformed(offset: position) }
            var field = String.UnicodeScalarView()
            field.append(contentsOf: scalars[position..<position + length])
            fields.append(String(field))
            position += length
        }
        return fields
    }

    // The Swift side of `put`, for tests and for building expected payloads.
    public static func encode(_ fields: [String?]) -> String {
        fields.map { field in
            guard let field else { return "~" }
            return "\(field.unicodeScalars.count):\(field)"
        }.joined()
    }
}

struct OracleDebugPayloadReader {
    private var fields: ArraySlice<String?>

    init(_ fields: [String?]) {
        self.fields = fields[...]
    }

    var isAtEnd: Bool { fields.isEmpty }

    mutating func next() throws -> String? {
        guard let field = fields.popFirst() else { throw OracleDebugError.unreadableAnswer }
        return field
    }

    mutating func int() throws -> Int? {
        try next().flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
}
