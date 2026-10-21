#!/usr/bin/env bash
#
# Build the large-catalog fixtures from #3661, for timing the sidebar, Open Quickly and autocomplete
# on a catalog of 50,000 tables.
#
#   postgres  database tablepro_large_catalog: 100 schemas lc_s001..lc_s100, 500 tables each
#   oracle    100 users LC_S001..LC_S100, 500 tables each, in a gvenzl/oracle-free container
#   mysql     database tablepro_large_catalog: 50,000 tables
#
# Every schema holds the same table names (lc_t001..lc_t500), as a tenant-per-schema database does,
# so a search for lc_t250 matches once per schema.
#
# Usage:
#   scripts/probes/build-large-catalog-fixtures.sh postgres [host] [port] [user]
#   scripts/probes/build-large-catalog-fixtures.sh mysql [host] [port] [user]
#   scripts/probes/build-large-catalog-fixtures.sh oracle [container] [system-password]
#   scripts/probes/build-large-catalog-fixtures.sh drop-postgres|drop-mysql|drop-oracle [same arguments]
#
# Oracle runs SQL*Plus inside the container. Start one with:
#   docker run -d --name oracle-large-catalog -p 1521:1521 -e ORACLE_PASSWORD=probe_pw \
#     gvenzl/oracle-free:23-slim-faststart
#
# SCHEMAS, TABLES_PER_SCHEMA, TABLES (the MySQL table count) and DATABASE override the defaults.
# Re-running skips a schema that already holds every table. Exits 3 when a client or server is missing.

set -uo pipefail

ENGINE="${1:-}"
SCHEMAS="${SCHEMAS:-100}"
TABLES_PER_SCHEMA="${TABLES_PER_SCHEMA:-500}"
MYSQL_TABLES="${TABLES:-50000}"
DATABASE="${DATABASE:-tablepro_large_catalog}"
# Wide enough for the largest number, so an override never truncates two names into one.
SCHEMA_WIDTH=$(( ${#SCHEMAS} > 3 ? ${#SCHEMAS} : 3 ))
TABLE_WIDTH=$(( ${#TABLES_PER_SCHEMA} > 3 ? ${#TABLES_PER_SCHEMA} : 3 ))
MYSQL_WIDTH=$(( ${#MYSQL_TABLES} > 5 ? ${#MYSQL_TABLES} : 5 ))

need() {
    command -v "$1" > /dev/null || {
        echo "$1 not found" >&2
        exit 3
    }
}

elapsed_since() {
    echo "$(( $(date +%s) - $1 ))s"
}

postgres_fixture() {
    local host="${1:-127.0.0.1}" port="${2:-5432}" user="${3:-postgres}" started schema i
    need psql
    psql_at() {
        psql -X -q -v ON_ERROR_STOP=1 -h "$host" -p "$port" -U "$user" -d "$1" "${@:2}"
    }
    psql_at postgres -Atc "SELECT 1" > /dev/null 2>&1 || {
        echo "no PostgreSQL at $host:$port as $user" >&2
        exit 3
    }
    if [ -z "$(psql_at postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '$DATABASE'")" ]; then
        psql_at postgres -c "CREATE DATABASE $DATABASE"
    fi
    started=$(date +%s)
    for i in $(seq 1 "$SCHEMAS"); do
        schema=$(printf 'lc_s%0*d' "$SCHEMA_WIDTH" "$i")
        # One transaction per schema: 50,000 tables in one would overrun the shared lock table.
        psql_at "$DATABASE" -c "
            CREATE SCHEMA IF NOT EXISTS $schema;
            DO \$\$
            BEGIN
                FOR t IN 1..$TABLES_PER_SCHEMA LOOP
                    EXECUTE format('CREATE TABLE IF NOT EXISTS $schema.%I (id integer PRIMARY KEY, name text)',
                                   'lc_t' || lpad(t::text, $TABLE_WIDTH, '0'));
                END LOOP;
            END
            \$\$;" > /dev/null || exit 1
        [ $((i % 10)) -eq 0 ] && echo "postgres: $i of $SCHEMAS schemas, $(elapsed_since "$started")"
    done
    echo "postgres: $(psql_at "$DATABASE" -Atc "SELECT count(*) FROM pg_tables WHERE schemaname LIKE 'lc!_s%' ESCAPE '!'") tables in $DATABASE"
}

postgres_drop() {
    local host="${1:-127.0.0.1}" port="${2:-5432}" user="${3:-postgres}"
    need psql
    psql -X -q -h "$host" -p "$port" -U "$user" -d postgres -c "DROP DATABASE IF EXISTS $DATABASE"
}

mysql_fixture() {
    local host="${1:-127.0.0.1}" port="${2:-3306}" user="${3:-root}" started batch i
    need mysql
    mysql_do() {
        mysql --protocol=TCP -h "$host" -P "$port" -u "$user" "$@"
    }
    mysql_do -e "SELECT 1" > /dev/null 2>&1 || {
        echo "no MySQL at $host:$port as $user (MYSQL_PWD supplies a password)" >&2
        exit 3
    }
    mysql_do -e "CREATE DATABASE IF NOT EXISTS $DATABASE"
    started=$(date +%s)
    batch=""
    for i in $(seq 1 "$MYSQL_TABLES"); do
        batch+="CREATE TABLE IF NOT EXISTS $(printf 'lc_t%0*d' "$MYSQL_WIDTH" "$i") (id INT PRIMARY KEY, name VARCHAR(64));"
        if [ $((i % 1000)) -eq 0 ] || [ "$i" -eq "$MYSQL_TABLES" ]; then
            mysql_do "$DATABASE" -e "$batch" || exit 1
            batch=""
            [ $((i % 5000)) -eq 0 ] && echo "mysql: $i of $MYSQL_TABLES tables, $(elapsed_since "$started")"
        fi
    done
    echo "mysql: $(mysql_do -N -e "SELECT count(*) FROM information_schema.tables WHERE table_schema = '$DATABASE'") tables in $DATABASE"
}

mysql_drop() {
    local host="${1:-127.0.0.1}" port="${2:-3306}" user="${3:-root}"
    need mysql
    mysql --protocol=TCP -h "$host" -P "$port" -u "$user" -e "DROP DATABASE IF EXISTS $DATABASE"
}

oracle_sqlplus() {
    docker exec -i "$1" sqlplus -s -L "system/$2@FREEPDB1"
}

oracle_check() {
    need docker
    printf 'SELECT 1 FROM dual;\nEXIT\n' | oracle_sqlplus "$1" "$2" > /dev/null 2>&1 || {
        echo "no Oracle container $1 answering as system (see the header for docker run)" >&2
        exit 3
    }
}

oracle_fixture() {
    local container="${1:-oracle-large-catalog}" password="${2:-probe_pw}" started
    oracle_check "$container" "$password"
    started=$(date +%s)
    # Deferred segment creation keeps an empty table to a dictionary row, so 50,000 build in minutes.
    oracle_sqlplus "$container" "$password" <<SQL || exit 1
WHENEVER SQLERROR EXIT FAILURE
DECLARE
    owner_name VARCHAR2(30);
    present NUMBER;
BEGIN
    FOR s IN 1..$SCHEMAS LOOP
        owner_name := 'LC_S' || LPAD(s, $SCHEMA_WIDTH, '0');
        SELECT COUNT(*) INTO present FROM dba_users WHERE username = owner_name;
        IF present = 0 THEN
            EXECUTE IMMEDIATE 'CREATE USER ' || owner_name || ' IDENTIFIED BY probe_pw QUOTA UNLIMITED ON USERS';
        END IF;
        SELECT COUNT(*) INTO present FROM dba_tables WHERE owner = owner_name;
        CONTINUE WHEN present >= $TABLES_PER_SCHEMA;
        FOR t IN 1..$TABLES_PER_SCHEMA LOOP
            BEGIN
                EXECUTE IMMEDIATE 'CREATE TABLE ' || owner_name || '.LC_T' || LPAD(t, $TABLE_WIDTH, '0')
                    || ' (id NUMBER PRIMARY KEY, name VARCHAR2(64)) SEGMENT CREATION DEFERRED';
            EXCEPTION
                -- ORA-00955: the table is there from an earlier run.
                WHEN OTHERS THEN IF SQLCODE != -955 THEN RAISE; END IF;
            END;
        END LOOP;
    END LOOP;
END;
/
SELECT COUNT(*) || ' tables' FROM dba_tables WHERE REGEXP_LIKE(owner, '^LC_S[0-9]+$');
EXIT
SQL
    echo "oracle: built in $(elapsed_since "$started")"
}

oracle_drop() {
    local container="${1:-oracle-large-catalog}" password="${2:-probe_pw}"
    oracle_check "$container" "$password"
    oracle_sqlplus "$container" "$password" <<SQL
BEGIN
    FOR u IN (SELECT username FROM dba_users WHERE REGEXP_LIKE(username, '^LC_S[0-9]+$')) LOOP
        EXECUTE IMMEDIATE 'DROP USER ' || u.username || ' CASCADE';
    END LOOP;
END;
/
EXIT
SQL
}

case "$ENGINE" in
    postgres) postgres_fixture "${@:2}" ;;
    mysql) mysql_fixture "${@:2}" ;;
    oracle) oracle_fixture "${@:2}" ;;
    drop-postgres) postgres_drop "${@:2}" ;;
    drop-mysql) mysql_drop "${@:2}" ;;
    drop-oracle) oracle_drop "${@:2}" ;;
    *)
        sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
        exit 3
        ;;
esac
