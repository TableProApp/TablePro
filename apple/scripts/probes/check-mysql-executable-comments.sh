#!/usr/bin/env bash
#
# Check SQLExecutableCommentReadings against live MySQL, MariaDB and TiDB servers.
#
# Packages/TableProCore/Sources/TableProSQLGrammar/SQLExecutableCommentReadings.swift says which `/*! */` comments a
# server runs, skips or reads as plain, by product and version. Safe Mode tiers a statement by those texts, so a rule
# that is wrong there lets a server run a DROP the gate never saw. This sends texts that hide a `DROP TABLE` behind one
# comment form each, as one query per text, and checks that the server dropped the table exactly when the model's text
# for that server's product and version shows the DROP.
#
# Usage:
#   scripts/probes/check-mysql-executable-comments.sh
#
# Each server is skipped unless its connection is set in the environment, as mysql client arguments:
#   MYSQL_ARGS       "-h 127.0.0.1 -P 13306 -uroot -pprobe"
#   MARIADB_ARGS     "-h 127.0.0.1 -P 13307 -uroot -pprobe"
#   TIDB_ARGS        "-h 127.0.0.1 -P 14000 -uroot"
#
# Throwaway servers that match those defaults:
#   docker run -d --name probe-mysql -p 13306:3306 -e MYSQL_ROOT_PASSWORD=probe mysql:8.4
#   docker run -d --name probe-mariadb -p 13307:3306 -e MARIADB_ROOT_PASSWORD=probe mariadb:11.4
#   docker run -d --name probe-tidb -p 14000:4000 pingcap/tidb:v8.5.1
#
# Each text goes through --init-command, which libmysqlclient sends as one query and the client's own statement
# splitter never reads. The probe works in a scratch database of its own and drops only that one.
# Exits non-zero on a disagreement, 3 when nothing could be checked.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DATABASE="tp_executable_comment_probe"

if [ -z "${DEVELOPER_DIR:-}" ]; then
    for candidate in /Applications/Xcode-beta.app /Applications/Xcode.app; do
        if [ -d "$candidate/Contents/Developer" ]; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            break
        fi
    done
fi
command -v swift > /dev/null || {
    echo "swift not found" >&2
    exit 3
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/Probe"

cat > "$WORK/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Probe",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$ROOT/Packages/TableProCore")],
    targets: [
        .executableTarget(
            name: "Probe",
            dependencies: [.product(name: "TableProSQLGrammar", package: "TableProCore")]
        )
    ]
)
EOF

cat > "$WORK/Sources/Probe/main.swift" <<'EOF'
import Foundation
import TableProSQLGrammar

let grammar = SQLLexicalReadings.resolve(databaseTypeId: "MySQL", declared: nil, session: nil).execution
let families: [String: SQLExecutableCommentReadings.Family] = [
    "mySQL5": .mySQL5, "mySQL81": .mySQL81, "mariaDB": .mariaDB, "tiDB": .tiDB,
]

while let line = readLine() {
    let fields = line.split(separator: "\t").map(String.init)
    guard fields.count == 3, let family = families[fields[0]], let version = Int(fields[1]),
          let data = Data(base64Encoded: fields[2]), let sql = String(data: data, encoding: .utf8)
    else {
        print("?")
        continue
    }
    let server = SQLExecutableCommentReadings.Server(family: family, version: version)
    let text = SQLExecutableCommentReadings.text(of: sql, grammar: grammar, on: server)
    let drops = SQLStatementScanner.executableStatements(in: text, grammar: grammar).contains { statement in
        let code = SQLCodeProjection.code(of: statement.sql, grammar: grammar)
        return code.range(of: #"DROP\s+TABLE\s+t\b"#, options: .regularExpression) != nil
    }
    print(drops ? 1 : 0)
}
EOF

echo "Building the probe against Packages/TableProCore (the first build takes a minute)"
(cd "$WORK" && swift build -c debug > "$WORK/build.log" 2>&1) || {
    grep -E "error:" "$WORK/build.log" | head -20 >&2
    exit 3
}
PROBE="$WORK/.build/debug/Probe"

CASES=(
    "/*!99999 ' */ DROP TABLE t -- '"
    "/*!50700 ' */ DROP TABLE t -- '"
    "/*!40101 ' */ DROP TABLE t -- '"
    "/*!100000 ' */ DROP TABLE t -- '"
    "/*!800000 ' */ DROP TABLE t -- '"
    "/*!800000' */ DROP TABLE t -- '"
    "/*!8000000 ' */ DROP TABLE t -- '"
    "/*!80047 ' */ DROP TABLE t -- '"
    "/*!DROP TABLE t */"
    "/*!99999 /* */ ' */ DROP TABLE t -- '"
    "/*!99999 /* /* */ */ ' */ DROP TABLE t -- '"
    "/*!99999 # ' */ DROP TABLE t -- '"
    "/*M! ' */ DROP TABLE t -- '"
    "/*M!999999 ' */ DROP TABLE t -- '"
    "/*M!99999 ' */ DROP TABLE t -- '"
    "/*M! /* */ ' */ DROP TABLE t -- '"
    "/*m! ' */ DROP TABLE t -- '"
    "/*! /* ' */ DROP TABLE t */"
    $'/*! DROP TABLE t # */ \'\n */'
    "/*! DROP TABLE /*! t */"
    "SELECT /*!50000 \"*/\", */ 1; /*!99999 ' */ DROP TABLE t -- '"
    "SELECT /*!80000 \"*/\", */ 1; /*!80100 ' */ DROP TABLE t -- '"
    "SELECT 1--/*!99999 ' */1; DROP TABLE t -- '"
    "/*T! DROP TABLE t */"
    "/*T![clustered_index] DROP TABLE t */"
)

failures=0
checked=0

check_server() {
    local name="$1" client="$2" args="$3"
    read -r -a argv <<< "$args"
    if ! command -v "$client" > /dev/null 2>&1; then
        echo "$name: no $client client, skipped"
        return
    fi
    local version
    version=$("$client" "${argv[@]}" -N -e "SELECT VERSION()" 2> /dev/null) || {
        echo "$name: cannot connect, skipped"
        return
    }
    local family numbers major minor patch id
    numbers="${version%%-*}"
    IFS=. read -r major minor patch <<< "$numbers"
    id=$((major * 10000 + minor * 100 + ${patch:-0}))
    if [[ "$version" == *TiDB* ]]; then
        family="tiDB"
    elif [[ "$version" == *MariaDB* ]]; then
        family="mariaDB"
    elif [ "$id" -ge 80100 ]; then
        family="mySQL81"
    else
        family="mySQL5"
    fi
    echo "$name: $version ($family $id)"
    checked=$((checked + 1))

    for sql in "${CASES[@]}"; do
        "$client" "${argv[@]}" -e "DROP DATABASE IF EXISTS $DATABASE; CREATE DATABASE $DATABASE; \
            CREATE TABLE $DATABASE.t (id INT)" > /dev/null 2>&1
        "$client" "${argv[@]}" -D "$DATABASE" --init-command="$sql" -e "SELECT 1" > /dev/null 2>&1
        local remaining dropped expected
        remaining=$("$client" "${argv[@]}" -N -e "SELECT COUNT(*) FROM information_schema.tables \
            WHERE table_schema = '$DATABASE' AND table_name = 't'" 2> /dev/null)
        dropped=$([ "$(echo "$remaining" | tr -d '[:space:]')" = "0" ] && echo 1 || echo 0)
        expected=$(printf '%s\t%s\t%s\n' "$family" "$id" "$(printf '%s' "$sql" | base64 | tr -d '\n')" | "$PROBE")
        if [ "$dropped" = "$expected" ]; then
            echo "  ok    $(printf '%q' "$sql")"
        else
            echo "  FAIL  $(printf '%q' "$sql"): server dropped=$dropped, model=$expected"
            failures=$((failures + 1))
        fi
    done
    "$client" "${argv[@]}" -e "DROP DATABASE IF EXISTS $DATABASE" > /dev/null 2>&1
}

[ -n "${MYSQL_ARGS:-}" ] && check_server "MySQL" mysql "$MYSQL_ARGS"
[ -n "${MARIADB_ARGS:-}" ] && check_server "MariaDB" mariadb "$MARIADB_ARGS"
[ -n "${TIDB_ARGS:-}" ] && check_server "TiDB" mysql "$TIDB_ARGS"

if [ "$checked" -eq 0 ]; then
    echo "No server checked: set MYSQL_ARGS or MARIADB_ARGS" >&2
    exit 3
fi
[ "$failures" -eq 0 ] || exit 1
