#!/usr/bin/env bash
#
# Compare the MySQL driver's character-set decoders against a real server.
#
# MySQLCharacterSet maps a server charset name to a Foundation encoding by hand, and MySQLLatin1
# carries MySQL's own latin1 table, which is cp1252 with five bytes passed through as C1
# controls. Both are transcriptions of what the server does, and Foundation's idea of a charset
# disagrees with MySQL's for several names that look identical (latin1, greek, hebrew, sjis). This
# asks the server how it converts every byte of every single-byte charset in the table, and a set
# of sample strings for the multibyte ones, and fails if the Swift decoders disagree.
#
# Usage:
#   scripts/check-mysql-charset-decoding.sh [host] [port] [user]
#
# Needs the mysql client, xcrun swiftc, and a MySQL 8 or MariaDB 10.5+ server. The password, if
# any, comes from MYSQL_PWD. A byte the server leaves undefined may decode to a replacement
# character or pass through as its own code point, as MySQL's latin1 does. Exits non-zero on a
# disagreement.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-3306}"
USER_NAME="${3:-root}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$ROOT/Plugins/MySQLDriverPlugin"

command -v mysql > /dev/null || {
    echo "mysql client not found" >&2
    exit 3
}

MYSQL=(mysql --no-defaults -h "$HOST" -P "$PORT" -u "$USER_NAME" -N -B -r --default-character-set=utf8mb4)
if ! "${MYSQL[@]}" -e "SELECT 1" > /dev/null 2>&1; then
    echo "no MySQL at $HOST:$PORT for $USER_NAME" >&2
    exit 3
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

func bytes(fromHex hex: Substring) -> [UInt8]? {
    guard hex.count % 2 == 0 else { return nil }
    var result: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
        result.append(byte)
        index = next
    }
    return result
}

func decode(_ input: [UInt8], _ name: String) -> String {
    input.withUnsafeBytes { MySQLCharacterSet(serverName: name).decode($0) }
}

let arguments = CommandLine.arguments
if arguments.count == 2, arguments[1] == "names" {
    for name in ["latin1"] + MySQLCharacterSet.singleByteDecodedNames {
        print("\(name) single")
    }
    for name in MySQLCharacterSet.multiByteDecodedNames {
        print("\(name) multi")
    }
    exit(0)
}

var failures = 0
for line in (try String(contentsOfFile: arguments[1], encoding: .utf8)).split(separator: "\n") {
    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
    guard fields.count >= 3 else { continue }
    let name = String(fields[0])
    switch fields[1] {
    case "byte":
        guard let byte = UInt8(fields[2], radix: 16), fields.count == 4,
              fields[3] != "NULL", let server = bytes(fromHex: fields[3]) else { continue }
        let undefined = server == [0x3F] && byte != 0x3F
        let local = decode([byte], name)
        let passThrough = String(Unicode.Scalar(byte))
        let acceptable = undefined ? ["\u{FFFD}", "?", passThrough] : [String(decoding: server, as: UTF8.self)]
        if !acceptable.contains(local) {
            print("\(name) byte \(fields[2]): server \(fields[3]) local \(local.unicodeScalars.map { String($0.value, radix: 16) })")
            failures += 1
        }
    case "sample":
        guard fields.count == 5, let encoded = bytes(fromHex: fields[3]), let back = bytes(fromHex: fields[4]) else {
            continue
        }
        let sample = String(fields[2])
        guard String(decoding: back, as: UTF8.self) == sample else { continue }
        let local = decode(encoded, name)
        if local != sample {
            print("\(name) sample \(sample): local \(local)")
            failures += 1
        }
    default:
        continue
    }
}
print(failures == 0 ? "OK" : "\(failures) disagreements")
exit(failures == 0 ? 0 : 1)
SWIFT

xcrun swiftc -O -o "$WORK/check" "$WORK/main.swift" \
    "$PLUGIN/MySQLCharacterSet.swift" "$PLUGIN/MySQLLatin1.swift" > "$WORK/build.log" 2>&1 || {
    cat "$WORK/build.log" >&2
    exit 3
}

SAMPLES=("メール・記事紐付け" "～" "〜" "①" "髙" "¥" "\\" "‖" "¬" "㈱" '“' "€" "中文简体" "繁體中文"
    "한국어" "Привет" "ґєії" "ąčęėįšųūž" "ğışİ" "łóźżćńśŁ" "àéüß" "😀" "ｱｲｳ" "∑" "×" $'\xe2\x80\x94' "£")

NAMES="$("$WORK/check" names)" && [ -n "$NAMES" ] || {
    echo "the decoder listed no character sets" >&2
    exit 3
}

: > "$WORK/server.tsv"
: > "$WORK/mysql.err"
while read -r NAME KIND; do
    KNOWN="$("${MYSQL[@]}" -e "SELECT COUNT(*) FROM information_schema.CHARACTER_SETS WHERE CHARACTER_SET_NAME = '$NAME'" 2>> "$WORK/mysql.err")"
    if [ "$KNOWN" != "1" ]; then
        echo "skipped $NAME: this server has no such character set"
        continue
    fi
    if [ "$KIND" = "single" ]; then
        COLUMNS=""
        for BYTE in $(seq 0 255); do
            HEX="$(printf '%02X' "$BYTE")"
            COLUMNS="$COLUMNS${COLUMNS:+,}CONCAT('$NAME\tbyte\t$HEX\t', IFNULL(HEX(CONVERT(CONVERT(UNHEX('$HEX') USING $NAME) USING utf8mb4)), 'NULL'))"
        done
        "${MYSQL[@]}" -e "SELECT $COLUMNS" 2>> "$WORK/mysql.err" | tr '\t' '\n' | paste - - - - >> "$WORK/server.tsv"
    fi
    for SAMPLE in "${SAMPLES[@]}"; do
        LITERAL="${SAMPLE//\\/\\\\}"
        "${MYSQL[@]}" -e "SELECT '$NAME', 'sample', _utf8mb4'$LITERAL', HEX(CONVERT(_utf8mb4'$LITERAL' USING $NAME)), HEX(CONVERT(CONVERT(_utf8mb4'$LITERAL' USING $NAME) USING utf8mb4))" \
            >> "$WORK/server.tsv" 2>> "$WORK/mysql.err"
    done
done <<< "$NAMES"

if grep -v -e '^WARNING' -e '^$' "$WORK/mysql.err" > /dev/null; then
    grep -v -e '^WARNING' "$WORK/mysql.err" >&2
    exit 3
fi

"$WORK/check" "$WORK/server.tsv"
