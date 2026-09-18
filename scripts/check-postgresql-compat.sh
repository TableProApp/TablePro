#!/bin/bash
#
# Runs the real PostgreSQL driver against one live server and checks what its catalog reads return.
#
# The driver's catalog SQL is hand-written, and a construct a newer server added fails at parse time
# on an older one, even inside a CASE branch that never runs. Nothing at runtime notices until a
# user on that server opens the sidebar. Every read below failed or answered wrongly on some
# PostgreSQL release before it was rewritten (#2734): to_regclass(text) is 9.6, LATERAL is 9.3,
# unnest WITH ORDINALITY and json_build_object are 9.4, to_json and json_agg are 9.3, pg_sequences
# and collprovider are 10, and array_position is 9.5.
#
# Builds TableProPluginKit and every PostgreSQL driver source with swiftc, loads a fixture into a
# scratch database, prints one canonical line per object each read returns, and diffs that against
# the answers below. A second pass connects as a role that owns nothing, because a read that works
# for the owner can still fail for a reader (a sequence the role cannot SELECT, for one). Overloads,
# aggregates and trigger WHEN clauses are in the fixture because the routine and trigger reads only
# go wrong with them present.
#
# Run it against each server you care about, oldest first. Docker has images from 9.1 on:
#   docker run -d --rm -e POSTGRES_PASSWORD=probe -p 127.0.0.1:54091:5432 postgres:9.1
#   PGPASSWORD=probe scripts/check-postgresql-compat.sh 127.0.0.1 54091
#
# Usage: scripts/check-postgresql-compat.sh [host] [port] [--keep]
# Environment: PGUSER (default postgres, must be a superuser), PGPASSWORD, PSQL.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:-127.0.0.1}"
PORT="${2:-5432}"
KEEP=0
[[ "${3:-}" == "--keep" ]] && KEEP=1
OWNER="${PGUSER:-postgres}"
DATABASE="tablepro_compat_check"
READER="tablepro_compat_reader"
READER_PASSWORD="tablepro_compat_reader"

WORK="$(mktemp -d)"
[[ "$KEEP" == "1" ]] && echo "Working directory: $WORK"

PSQL="${PSQL:-$(command -v psql || true)}"
if [[ -z "$PSQL" ]]; then
    echo "FAIL: psql not found; set PSQL" >&2
    exit 2
fi

run_psql() {
    "$PSQL" -X -q -v ON_ERROR_STOP=1 -h "$HOST" -p "$PORT" -U "$OWNER" "$@"
}

if ! run_psql -d postgres -Atc 'SELECT 1' > /dev/null 2>&1; then
    echo "FAIL: cannot connect to $HOST:$PORT as $OWNER" >&2
    exit 2
fi
SERVER_VERSION="$(run_psql -d postgres -Atc "SELECT current_setting('server_version_num')")"
echo "Checking against PostgreSQL $(run_psql -d postgres -Atc 'SHOW server_version') ($SERVER_VERSION) at $HOST:$PORT"

# Reports why it could not drop rather than hiding it: the CREATE DATABASE that follows would fail
# with "already exists", which names neither the leftover fixture nor the session still holding it.
drop_fixture() {
    local output
    if ! output="$(run_psql -d postgres -c "DROP DATABASE IF EXISTS $DATABASE" 2>&1)"; then
        echo "$output" >&2
        return 1
    fi
    if ! output="$(run_psql -d postgres -c "DROP ROLE IF EXISTS $READER" 2>&1)"; then
        echo "$output" >&2
        return 1
    fi
}
cleanup() {
    drop_fixture || echo "warning: fixture left behind; drop $DATABASE and $READER by hand" >&2
    [[ "$KEEP" == "1" ]] || rm -rf "$WORK"
}
trap cleanup EXIT

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    for candidate in /Applications/Xcode-beta.app/Contents/Developer /Applications/Xcode.app/Contents/Developer; do
        if [[ -d "$candidate/usr/bin" ]]; then
            export DEVELOPER_DIR="$candidate"
            break
        fi
    done
fi

KIT_DIR="$REPO_ROOT/Plugins/TableProPluginKit"
DRIVER_DIR="$REPO_ROOT/Plugins/PostgreSQLDriverPlugin"
LIBS="$REPO_ROOT/Libs"
for required in "$LIBS/libpq.a" "$LIBS/libpgcommon.a" "$LIBS/libpgport.a" "$LIBS/dylibs/libssl.3.dylib"; do
    if [[ ! -e "$required" ]]; then
        echo "FAIL: missing $required; run scripts/download-libs.sh" >&2
        exit 2
    fi
done

# The driver class reaches every file in its folder, so the folder is the unit rather than a list.
KIT_SOURCES=()
while IFS= read -r file; do KIT_SOURCES+=("$file"); done < <(find "$KIT_DIR" -name '*.swift' | sort)
DRIVER_SOURCES=()
while IFS= read -r file; do DRIVER_SOURCES+=("$file"); done < <(find "$DRIVER_DIR" -maxdepth 1 -name '*.swift' | sort)

cat > "$WORK/harness.swift" <<'SWIFT'
import Foundation
import TableProPluginKit

@main
enum CompatHarness {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 7 else {
            FileHandle.standardError.write(Data("usage: harness host port user password database owner|reader\n".utf8))
            exit(2)
        }
        let config = DriverConnectionConfig(
            host: arguments[1],
            port: Int(arguments[2]) ?? 5432,
            username: arguments[3],
            password: arguments[4],
            database: arguments[5]
        )
        let driver = PostgreSQLPluginDriver(config: config)
        do {
            try await driver.connect()
        } catch {
            print("error|connect|\(error.localizedDescription)")
            exit(1)
        }
        if arguments[6] == "reader" {
            await readerPass(driver)
        } else {
            await ownerPass(driver)
        }
        driver.disconnect()
    }

    static func line(_ fields: [String]) {
        print(fields.map { $0.replacingOccurrences(of: "\n", with: "\\n") }.joined(separator: "|"))
    }

    static func attempt(_ label: String, _ body: () async throws -> Void) async {
        do {
            try await body()
        } catch {
            line(["error", label, error.localizedDescription])
        }
    }

    static func ownerPass(_ driver: PostgreSQLPluginDriver) async {
        await attempt("fetchTables") {
            for table in try await driver.fetchTables(schema: "public") {
                line(["table", table.name, table.type, table.comment ?? "-"])
            }
        }
        await attempt("fetchAllForeignKeys") {
            let all = try await driver.fetchAllForeignKeys(schema: "public")
            for (table, keys) in all.sorted(by: { $0.key < $1.key }) {
                for (name, pairs) in foreignKeyPairs(keys) {
                    line(["fk", table, name, pairs])
                }
            }
        }
        await attempt("fetchForeignKeys") {
            for (name, pairs) in foreignKeyPairs(try await driver.fetchForeignKeys(table: "fk_child", schema: "public")) {
                line(["fk-table", "fk_child", name, pairs])
            }
            for (name, pairs) in foreignKeyPairs(try await driver.fetchForeignKeys(table: "part_child", schema: "public")) {
                line(["fk-table", "part_child", name, pairs])
            }
        }
        await attempt("fetchColumns") {
            for column in try await driver.fetchColumns(table: "orders", schema: "public") {
                line([
                    "column", "orders", column.name, column.dataType,
                    column.isNullable ? "null" : "not-null", column.isPrimaryKey ? "pk" : "-",
                    column.defaultValue ?? "-", column.comment ?? "-",
                    column.isIdentity ? "identity" : "-", column.isGenerated ? "generated" : "-"
                ])
            }
        }
        await attempt("fetchAllColumns") {
            let all = try await driver.fetchAllColumns(schema: "public")
            for (table, columns) in all.sorted(by: { $0.key < $1.key }) {
                line(["columns", table, columns.map(\.name).joined(separator: ";")])
            }
        }
        await attempt("fetchTableDDL") {
            for table in ["orders", "Mixed Case", "we,ird"] {
                let ddl = try await driver.fetchTableDDL(table: table, schema: "public")
                let columns = try await driver.fetchColumns(table: table, schema: "public")
                line(["ddl", table, ddlShape(ddl, columns: columns)])
            }
        }
        await attempt("fetchAllIndexes") {
            let all = try await driver.fetchAllIndexes(schema: "public")
            for (table, indexes) in all.sorted(by: { $0.key < $1.key }) {
                for index in indexes {
                    line([
                        "index", table, index.name, index.columns.joined(separator: ";"),
                        index.isUnique ? "unique" : "-", index.isPrimary ? "primary" : "-", index.type,
                        index.whereClause ?? "-"
                    ])
                }
            }
        }
        await attempt("fetchIndexes") {
            for index in try await driver.fetchIndexes(table: "idx_t", schema: "public") {
                line(["index-table", "idx_t", index.name, index.columns.joined(separator: ";")])
            }
        }
        await attempt("fetchCheckConstraints") {
            for check in try await driver.fetchCheckConstraints(table: "we,ird", schema: "public") {
                line([
                    "check", "we,ird", check.name, check.expression, check.columns.joined(separator: ";"),
                    check.isValidated ? "validated" : "not-validated"
                ])
            }
        }
        await attempt("fetchAllTriggers") {
            for trigger in try await driver.fetchTriggers(table: "orders", schema: "public") {
                line([
                    "trigger", trigger.table ?? "-", trigger.name, trigger.timing, trigger.event,
                    trigger.orientation ?? "-", trigger.enabled == true ? "enabled" : "disabled"
                ])
                if trigger.name == "orders_touch" {
                    line(["trigger-when", trigger.name, (trigger.definition ?? "").contains(" WHEN ") ? "yes" : "no"])
                }
            }
        }
        await attempt("fetchUserDefinedTypes") {
            for type in try await driver.fetchUserDefinedTypes(schema: "public") {
                line(["type", type.name, type.definition ?? "-"])
            }
        }
        await attempt("fetchRoutines") {
            for routine in try await driver.fetchRoutines(schema: "public") {
                line(["routine", routine.name, routine.argumentSignature ?? "-"])
                guard routine.name == "transform", let signature = routine.argumentSignature else { continue }
                let ddl = try await driver.fetchRoutineDDL(routine)
                line(["routine-ddl", signature, ddl.contains("transform\(signature)") ? "yes" : "no"])
            }
        }
        await attempt("fetchSequences") {
            for sequence in try await driver.fetchSequences(schema: "public") {
                line(["sequence", sequence.name, sequence.ddl])
            }
        }
        await attempt("fetchDependentSequences") {
            for sequence in try await driver.fetchDependentSequences(table: "orders", schema: "public") {
                line(["dependent-sequence", "orders", sequence.name, sequence.ddl])
            }
        }
        await attempt("fetchGrants") {
            let grants = try await driver.fetchGrants(for: PluginPrincipalRef(name: "tablepro_compat_reader"))
            for grant in grants.map({ "\($0.scope)|\($0.privilege)" }).sorted() {
                print("grant|\(grant)")
            }
        }
        await attempt("createDatabaseFormSpec") {
            let template = try await driver.execute(query: "SELECT datcollate FROM pg_database WHERE datname = 'template1'")
            let collate = template.rows.first?.first?.asText ?? ""
            let spec = try await driver.createDatabaseFormSpec()
            var hasTemplateCollation = false
            if let field = spec?.fields.first(where: { $0.id == "collation" }),
               case .searchable(let options, _) = field.kind {
                hasTemplateCollation = options.contains { $0.value == collate }
            }
            line(["collations-include-template1", hasTemplateCollation ? "yes" : "no"])
        }
        await attempt("allTablesMetadataSQL") {
            guard let sql = driver.allTablesMetadataSQL(schema: "public") else { return }
            let result = try await driver.execute(query: sql)
            for row in result.rows where row[safe: 1]?.asText == "Mixed Case" {
                line(["all-tables", "Mixed Case", row[safe: 7]?.asText ?? "-"])
            }
        }
        await attempt("fetchTableMetadata") {
            let metadata = try await driver.fetchTableMetadata(table: "Mixed Case", schema: "public")
            line(["metadata", "Mixed Case", metadata.comment ?? "-"])
        }
        await attempt("fetchViewDefinition") {
            let ddl = try await driver.fetchViewDefinition(view: "order_view", schema: "public")
            line(["view", (ddl.components(separatedBy: "\n").first ?? "-").trimmingCharacters(in: .whitespaces)])
        }
        await attempt("fetchViewDefinition(materialized)") {
            let tables = try await driver.fetchTables(schema: "public")
            guard tables.contains(where: { $0.name == "order_totals" }) else { return }
            let ddl = try await driver.fetchViewDefinition(view: "order_totals", schema: "public")
            line(["view", (ddl.components(separatedBy: "\n").first ?? "-").trimmingCharacters(in: .whitespaces)])
        }
    }

    static func readerPass(_ driver: PostgreSQLPluginDriver) async {
        await attempt("fetchTables") {
            line(["reader-tables", "\(try await driver.fetchTables(schema: "public").count > 0)"])
        }
        await attempt("fetchAllForeignKeys") {
            line(["reader-fks", "\(try await driver.fetchAllForeignKeys(schema: "public").count > 0)"])
        }
        await attempt("fetchUserDefinedTypes") {
            line(["reader-types", "\(try await driver.fetchUserDefinedTypes(schema: "public").count > 0)"])
        }
        await attempt("fetchSequences") {
            for sequence in try await driver.fetchSequences(schema: "public") {
                line(["reader-sequence", sequence.name, sequence.ddl])
            }
        }
    }

    /// The statement text differs by release (serial versus identity, how defaults print), so the
    /// check pins what every release must produce: a terminated CREATE TABLE naming every column
    /// the column read returned, with the primary key carried over.
    static func ddlShape(_ ddl: String, columns: [PluginColumnInfo]) -> String {
        let named = columns.allSatisfy { column in
            let quoted = "\"\(column.name.replacingOccurrences(of: "\"", with: "\"\""))\""
            return ddl.contains("\n  \(quoted) ") || ddl.contains("\n  \(column.name) ")
        }
        return [
            ddl.hasPrefix("CREATE TABLE ") ? "create" : "no-create",
            named ? "names-all-columns" : "misses-a-column",
            columns.contains(where: \.isPrimaryKey) == ddl.contains("PRIMARY KEY") ? "pk-consistent" : "pk-lost",
            ddl.contains(";") ? "terminated" : "unterminated"
        ].joined(separator: " ")
    }

    static func foreignKeyPairs(_ keys: [PluginForeignKeyInfo]) -> [(String, String)] {
        var order: [String] = []
        var pairs: [String: [String]] = [:]
        for key in keys {
            if pairs[key.name] == nil { order.append(key.name) }
            pairs[key.name, default: []].append("\(key.column)>\(key.referencedTable).\(key.referencedColumn) \(key.onDelete)/\(key.onUpdate)")
        }
        return order.sorted().map { ($0, pairs[$0, default: []].joined(separator: ",")) }
    }
}
SWIFT

echo "Building the harness from the shipping sources..."
BUILD="$WORK/build"
mkdir -p "$BUILD"
if ! xcrun swiftc -emit-library -emit-module -module-name TableProPluginKit -parse-as-library -swift-version 6 \
    -enable-library-evolution -Xlinker -install_name -Xlinker @rpath/libTableProPluginKit.dylib \
    -emit-module-path "$BUILD/TableProPluginKit.swiftmodule" -o "$BUILD/libTableProPluginKit.dylib" \
    "${KIT_SOURCES[@]}" > "$WORK/build-kit.log" 2>&1; then
    echo "FAIL: TableProPluginKit did not build" >&2
    grep -E "error" "$WORK/build-kit.log" | head -20 >&2
    exit 2
fi
if ! xcrun swiftc -parse-as-library -swift-version 6 -module-name PostgreSQLCompatHarness \
    -I "$BUILD" -L "$BUILD" -lTableProPluginKit \
    -I "$DRIVER_DIR/CLibPQ" -Xcc -I"$DRIVER_DIR/CLibPQ/include" \
    -Xlinker -force_load -Xlinker "$LIBS/libpq.a" "$LIBS/libpgcommon.a" "$LIBS/libpgport.a" \
    -L "$LIBS/dylibs" -lssl.3 -lcrypto.3 -lz \
    -Xlinker -rpath -Xlinker "$BUILD" -Xlinker -rpath -Xlinker "$LIBS/dylibs" \
    -o "$BUILD/harness" "${DRIVER_SOURCES[@]}" "$WORK/harness.swift" > "$WORK/build-harness.log" 2>&1; then
    echo "FAIL: the driver harness did not build" >&2
    grep -E "error" "$WORK/build-harness.log" | head -20 >&2
    exit 2
fi

if ! drop_fixture; then
    echo "FAIL: a leftover fixture could not be dropped; another session is probably connected to $DATABASE" >&2
    exit 2
fi
run_psql -d postgres -c "CREATE DATABASE $DATABASE" > /dev/null
run_psql -d postgres -c "CREATE ROLE $READER LOGIN PASSWORD '$READER_PASSWORD'" > /dev/null

run_psql -d "$DATABASE" > "$WORK/fixture.log" 2>&1 <<SQL
SELECT current_setting('server_version_num')::int >= 90200 AS pg92,
       current_setting('server_version_num')::int >= 90300 AS pg93,
       current_setting('server_version_num')::int >= 100000 AS pg10,
       current_setting('server_version_num')::int >= 110000 AS pg11,
       current_setting('server_version_num')::int >= 120000 AS pg12 \gset

CREATE TYPE mood AS ENUM ('very happy', 'sad,ish', 'NULL', 'q"t', '');
CREATE TYPE "odd,type" AS ("first name" text COLLATE "C", "q""t" integer, zip varchar(10));
CREATE DOMAIN checked AS text CONSTRAINT "has,comma" CHECK (VALUE <> '') CONSTRAINT b_len CHECK (length(VALUE) < 10);

CREATE TABLE customers (id bigserial PRIMARY KEY, email text NOT NULL UNIQUE);
COMMENT ON TABLE customers IS 'Customer accounts';
CREATE TABLE orders (
    id bigserial PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES customers (id) ON DELETE CASCADE,
    qty integer,
    status mood
);
COMMENT ON TABLE orders IS 'Orders';
INSERT INTO customers (email) VALUES ('a@x'), ('b@x');
INSERT INTO orders (customer_id, qty) VALUES (1, 150), (2, 5);
CREATE INDEX orders_big_qty ON orders (qty) WHERE qty > 100;
CREATE INDEX orders_multi ON orders (qty, customer_id);

CREATE TABLE fk_parent (a integer, b integer, PRIMARY KEY (a, b));
CREATE TABLE fk_child (x integer, y integer, CONSTRAINT fk_rev FOREIGN KEY (y, x) REFERENCES fk_parent (b, a) ON UPDATE CASCADE);

CREATE TABLE idx_t (a integer, b text, c integer, "d,e" integer);
CREATE INDEX idx_dup ON idx_t (a, a);
CREATE INDEX idx_mixed ON idx_t (c, lower(b), a);
CREATE INDEX idx_rev ON idx_t (c, a);
CREATE INDEX idx_weird ON idx_t ("d,e", b);

CREATE TABLE "we,ird" ("a b" integer, "c,d" integer, "q""t" integer,
    CONSTRAINT "we,ird_chk" CHECK ("a b" + "c,d" + "q""t" > 0), CONSTRAINT constant_chk CHECK (1 > 0));

CREATE TABLE "Mixed Case" ("Id" integer PRIMARY KEY);
COMMENT ON TABLE "Mixed Case" IS 'Mixed comment';

CREATE VIEW order_view AS SELECT id, qty FROM orders;
COMMENT ON VIEW order_view IS 'Order view';

CREATE SEQUENCE compat_seq INCREMENT 2 MINVALUE 5 MAXVALUE 50 START 7 CYCLE;
SELECT nextval('compat_seq');
CREATE SEQUENCE hidden_seq MAXVALUE 99;

CREATE FUNCTION transform(a integer) RETURNS integer LANGUAGE sql IMMUTABLE AS 'SELECT \$1';
CREATE FUNCTION transform(a text) RETURNS integer LANGUAGE sql AS 'SELECT 2';
CREATE AGGREGATE my_sum(integer) (SFUNC = int4pl, STYPE = integer);
CREATE FUNCTION touch() RETURNS trigger LANGUAGE plpgsql AS \$\$ BEGIN RETURN NEW; END \$\$;
CREATE TRIGGER orders_touch BEFORE INSERT OR UPDATE ON orders FOR EACH ROW WHEN (NEW.qty > 0) EXECUTE PROCEDURE touch();
CREATE TRIGGER orders_audit AFTER DELETE OR TRUNCATE ON orders FOR EACH STATEMENT EXECUTE PROCEDURE touch();
ALTER TABLE orders DISABLE TRIGGER orders_audit;

CREATE FOREIGN DATA WRAPPER compat_fdw;
CREATE SERVER compat_srv FOREIGN DATA WRAPPER compat_fdw;
CREATE FOREIGN TABLE remote_things (id integer) SERVER compat_srv;
COMMENT ON FOREIGN TABLE remote_things IS 'Remote comment';

GRANT CONNECT ON DATABASE $DATABASE TO $READER;
GRANT USAGE ON SCHEMA public TO $READER;
GRANT SELECT ON customers TO $READER;
GRANT SELECT (qty), UPDATE (qty) ON orders TO $READER;
GRANT USAGE ON SEQUENCE compat_seq TO $READER;

\if :pg92
ALTER TABLE "we,ird" ADD CONSTRAINT late_chk CHECK ("a b" > 0) NOT VALID;
\endif

\if :pg93
CREATE MATERIALIZED VIEW order_totals AS SELECT customer_id, sum(qty) AS total FROM orders GROUP BY customer_id;
COMMENT ON MATERIALIZED VIEW order_totals IS 'Totals';
\endif

\if :pg10
CREATE TABLE events (happened date NOT NULL) PARTITION BY RANGE (happened);
CREATE TABLE events_2024 PARTITION OF events FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
\endif

\if :pg11
CREATE PROCEDURE reset_qty() LANGUAGE sql AS 'UPDATE orders SET qty = 0';
\endif

\if :pg12
CREATE TABLE part_ref (id integer PRIMARY KEY) PARTITION BY RANGE (id);
CREATE TABLE part_ref_lo PARTITION OF part_ref FOR VALUES FROM (1) TO (100);
CREATE TABLE part_ref_hi PARTITION OF part_ref FOR VALUES FROM (100) TO (200);
CREATE TABLE part_child (ref_id integer REFERENCES part_ref (id));
CREATE TABLE part_src (id integer NOT NULL, cust bigint REFERENCES customers (id)) PARTITION BY RANGE (id);
CREATE TABLE part_src_1 PARTITION OF part_src FOR VALUES FROM (1) TO (10);
\endif
SQL

# One expected line per object. A leading "min-max|" limits a line to servers in that range of
# server_version_num; "-" leaves an end open.
cat > "$WORK/expected.txt" <<'EXPECTED'
-|table|Mixed Case|TABLE|Mixed comment
-|table|customers|TABLE|Customer accounts
-|table|fk_child|TABLE|-
-|table|fk_parent|TABLE|-
-|table|idx_t|TABLE|-
-|table|order_view|VIEW|Order view
-|table|orders|TABLE|Orders
-|table|remote_things|FOREIGN TABLE|Remote comment
-|table|we,ird|TABLE|-
90300-|table|order_totals|MATERIALIZED VIEW|Totals
100000-|table|events|PARTITIONED TABLE|-
120000-|table|part_child|TABLE|-
120000-|table|part_ref|PARTITIONED TABLE|-
120000-|table|part_src|PARTITIONED TABLE|-
-|fk|fk_child|fk_rev|y>fk_parent.b NO ACTION/CASCADE,x>fk_parent.a NO ACTION/CASCADE
-|fk|orders|orders_customer_id_fkey|customer_id>customers.id CASCADE/NO ACTION
120000-|fk|part_child|part_child_ref_id_fkey|ref_id>part_ref.id NO ACTION/NO ACTION
120000-|fk|part_src|part_src_cust_fkey|cust>customers.id NO ACTION/NO ACTION
120000-|fk|part_src_1|part_src_cust_fkey|cust>customers.id NO ACTION/NO ACTION
-|fk-table|fk_child|fk_rev|y>fk_parent.b NO ACTION/CASCADE,x>fk_parent.a NO ACTION/CASCADE
120000-|fk-table|part_child|part_child_ref_id_fkey|ref_id>part_ref.id NO ACTION/NO ACTION
-|index|Mixed Case|Mixed Case_pkey|Id|unique|primary|BTREE|-
-|index|customers|customers_pkey|id|unique|primary|BTREE|-
-|index|customers|customers_email_key|email|unique|-|BTREE|-
-|index|fk_parent|fk_parent_pkey|a;b|unique|primary|BTREE|-
-|index|idx_t|idx_dup|a|-|-|BTREE|-
-|column|orders|customer_id|BIGINT|not-null|-|-|-|-|-
-|column|orders|id|BIGINT|not-null|pk|nextval('orders_id_seq'::regclass)|-|-|-
-|column|orders|qty|INTEGER|null|-|-|-|-|-
-|column|orders|status|ENUM|null|-|-|-|-|-
-|columns|Mixed Case|Id
-|columns|customers|id;email
-|columns|fk_child|x;y
-|columns|fk_parent|a;b
-|columns|idx_t|a;b;c;d,e
-|columns|order_view|id;qty
-|columns|orders|id;customer_id;qty;status
-|columns|remote_things|id
-|columns|we,ird|a b;c,d;q"t
100000-|columns|events|happened
100000-|columns|events_2024|happened
120000-|columns|part_child|ref_id
120000-|columns|part_ref|id
120000-|columns|part_ref_hi|id
120000-|columns|part_ref_lo|id
120000-|columns|part_src|id;cust
120000-|columns|part_src_1|id;cust
-|ddl|Mixed Case|create names-all-columns pk-consistent terminated
-|ddl|orders|create names-all-columns pk-consistent terminated
-|ddl|we,ird|create names-all-columns pk-consistent terminated
120000-|index|part_ref|part_ref_pkey|id|unique|primary|BTREE|-
120000-|index|part_ref_hi|part_ref_hi_pkey|id|unique|primary|BTREE|-
120000-|index|part_ref_lo|part_ref_lo_pkey|id|unique|primary|BTREE|-
-|index|idx_t|idx_mixed|c;a|-|-|BTREE|-
-|index|idx_t|idx_rev|c;a|-|-|BTREE|-
-|index|idx_t|idx_weird|d,e;b|-|-|BTREE|-
-|index|orders|orders_pkey|id|unique|primary|BTREE|-
-|index|orders|orders_big_qty|qty|-|-|BTREE|(qty > 100)
-|index|orders|orders_multi|qty;customer_id|-|-|BTREE|-
-|index-table|idx_t|idx_dup|a
-|index-table|idx_t|idx_mixed|c;a
-|index-table|idx_t|idx_rev|c;a
-|index-table|idx_t|idx_weird|d,e;b
-|check|we,ird|constant_chk|1 > 0||validated
-|check|we,ird|we,ird_chk|(("a b" + "c,d") + "q""t") > 0|a b;c,d;q"t|validated
90200-|check|we,ird|late_chk|"a b" > 0|a b|not-validated
-|trigger|orders|orders_audit|AFTER|DELETE OR TRUNCATE|STATEMENT|disabled
-|trigger|orders|orders_touch|BEFORE|INSERT OR UPDATE|ROW|enabled
-|type|checked|CREATE DOMAIN "public"."checked" AS text\n    CONSTRAINT "b_len" CHECK ((length(VALUE) < 10))\n    CONSTRAINT "has,comma" CHECK ((VALUE <> ''::text));
-|type|mood|CREATE TYPE "public"."mood" AS ENUM (\n    'very happy',\n    'sad,ish',\n    'NULL',\n    'q"t',\n    ''\n);
-|type|odd,type|CREATE TYPE "public"."odd,type" AS (\n    "first name" text COLLATE pg_catalog."C",\n    "q""t" integer,\n    "zip" character varying(10)\n);
-|routine|touch|()
-|routine-ddl|(a integer)|yes
-|routine-ddl|(a text)|yes
-|trigger-when|orders_touch|yes
-|routine|transform|(a integer)
-|routine|transform|(a text)
110000-|routine|reset_qty|()
-|sequence|compat_seq|CREATE SEQUENCE "compat_seq" INCREMENT BY 2 MINVALUE 5 MAXVALUE 50 START WITH 7 CYCLE;\nSELECT pg_catalog.setval('"compat_seq"', 7, true);
-|sequence|customers_id_seq|CREATE SEQUENCE "customers_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1;\nSELECT pg_catalog.setval('"customers_id_seq"', 2, true);
-|sequence|hidden_seq|CREATE SEQUENCE "hidden_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 99 START WITH 1;
-|sequence|orders_id_seq|CREATE SEQUENCE "orders_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1;\nSELECT pg_catalog.setval('"orders_id_seq"', 2, true);
-|dependent-sequence|orders|orders_id_seq|CREATE SEQUENCE "orders_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1;\nSELECT pg_catalog.setval('"orders_id_seq"', 2, true);
-|grant|column(database: "tablepro_compat_check", schema: Optional("public"), table: "orders", column: "qty")|SELECT
-|grant|column(database: "tablepro_compat_check", schema: Optional("public"), table: "orders", column: "qty")|UPDATE
-|grant|database("tablepro_compat_check")|CONNECT
-|grant|schema(database: "tablepro_compat_check", schema: "public")|USAGE
-|grant|table(database: "tablepro_compat_check", schema: Optional("public"), table: "customers")|SELECT
-|collations-include-template1|yes
-|all-tables|Mixed Case|Mixed comment
-|metadata|Mixed Case|Mixed comment
-|view|CREATE OR REPLACE VIEW "public"."order_view" AS
90300-|view|CREATE MATERIALIZED VIEW "public"."order_totals" AS
EXPECTED

cat > "$WORK/expected-reader.txt" <<'EXPECTED'
-|reader-tables|true
-|reader-fks|true
-|reader-types|true
-99999|reader-sequence|customers_id_seq|CREATE SEQUENCE "customers_id_seq";
-99999|reader-sequence|orders_id_seq|CREATE SEQUENCE "orders_id_seq";
-99999|reader-sequence|hidden_seq|CREATE SEQUENCE "hidden_seq";
100000-|reader-sequence|customers_id_seq|CREATE SEQUENCE "customers_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1;
100000-|reader-sequence|orders_id_seq|CREATE SEQUENCE "orders_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1;
100000-|reader-sequence|hidden_seq|CREATE SEQUENCE "hidden_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 99 START WITH 1;
-99999|reader-sequence|compat_seq|CREATE SEQUENCE "compat_seq" INCREMENT BY 2 MINVALUE 5 MAXVALUE 50 START WITH 7 CYCLE;
100000-|reader-sequence|compat_seq|CREATE SEQUENCE "compat_seq" INCREMENT BY 2 MINVALUE 5 MAXVALUE 50 START WITH 7 CYCLE;\nSELECT pg_catalog.setval('"compat_seq"', 7, true);
EXPECTED

select_for_version() {
    awk -F'|' -v version="$SERVER_VERSION" '{
        range = $1
        split(range, bounds, "-")
        low = bounds[1] == "" ? 0 : bounds[1] + 0
        high = bounds[2] == "" ? 999999999 : bounds[2] + 0
        if (range == "-") { low = 0; high = 999999999 }
        if (version + 0 >= low && version + 0 <= high) {
            sub(/^[^|]*\|/, "")
            print
        }
    }' "$1" | LC_ALL=C sort
}

failures=0
compare() {
    local label="$1" expected="$2" actual="$3"
    if ! diff -u "$expected" "$actual" > "$WORK/$label.diff"; then
        echo "FAIL: $label reads disagree with the expected answers (- expected, + driver):" >&2
        tail -n +3 "$WORK/$label.diff" >&2
        failures=$((failures + 1))
    fi
}

# The harness prints one line per object and exits non-zero when it cannot even connect. Piping it
# straight into sort would let pipefail end the run through the EXIT trap, which deletes the working
# directory: the script whose job is diagnosis would print nothing to diagnose with.
run_pass() {
    local pass="$1" user="$2" password="$3" out="$4" status=0
    "$BUILD/harness" "$HOST" "$PORT" "$user" "$password" "$DATABASE" "$pass" \
        > "$WORK/$pass.raw" 2> "$WORK/$pass.err" || status=$?
    if [[ "$status" -ne 0 ]]; then
        echo "FAIL: the $pass harness pass exited $status" >&2
        tail -n 20 "$WORK/$pass.err" >&2
        tail -n 5 "$WORK/$pass.raw" >&2
        KEEP=1
        echo "Working directory kept for diagnosis: $WORK" >&2
        return 1
    fi
    LC_ALL=C sort "$WORK/$pass.raw" > "$out"
}

PGPASSWORD_OWNER="${PGPASSWORD:-}"
if run_pass owner "$OWNER" "$PGPASSWORD_OWNER" "$WORK/actual.txt"; then
    select_for_version "$WORK/expected.txt" > "$WORK/expected-selected.txt"
    compare owner "$WORK/expected-selected.txt" "$WORK/actual.txt"
else
    failures=$((failures + 1))
fi

if run_pass reader "$READER" "$READER_PASSWORD" "$WORK/actual-reader.txt"; then
    select_for_version "$WORK/expected-reader.txt" > "$WORK/expected-reader-selected.txt"
    compare reader "$WORK/expected-reader-selected.txt" "$WORK/actual-reader.txt"
else
    failures=$((failures + 1))
fi

if [[ "$failures" -gt 0 ]]; then
    echo "$failures pass(es) disagreed on PostgreSQL $SERVER_VERSION" >&2
    exit 1
fi
echo "PostgreSQL driver catalog reads agree on PostgreSQL $SERVER_VERSION"
