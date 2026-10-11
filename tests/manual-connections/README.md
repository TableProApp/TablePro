# Manual connection fixture

This Compose project starts one disposable service per network database driver. Every published port is bound to `127.0.0.1`; the credentials below are fixed local-fixture values, not production credentials.

SQLite and DuckDB are embedded file databases. They do not run as network services and are listed separately below.

## Start and stop

Run from the repository root:

```bash
docker compose -f tests/manual-connections/docker-compose.yml up -d
```

Check the long-running services are healthy and the `mssql-init` one-shot service completed without SQL errors before testing SQL Server:

```bash
docker compose -f tests/manual-connections/docker-compose.yml ps
docker compose -f tests/manual-connections/docker-compose.yml logs mssql-init
```

Reset all data and users:

```bash
docker compose -f tests/manual-connections/docker-compose.yml down --volumes --remove-orphans
docker compose -f tests/manual-connections/docker-compose.yml up -d
```

Stop the fixture without removing its current data:

```bash
docker compose -f tests/manual-connections/docker-compose.yml down
```

## App connections

Set TLS to **Disabled** for every network connection. Each service has a `people` table or collection with two rows. Test both the read-write and read-only users: the latter must browse and query, but writes must be denied by the database.

| Driver | Host | Port | Database | Read-write user | Read-only user |
|---|---:|---:|---|---|---|
| PostgreSQL | `127.0.0.1` | `15432` | `tablepro_lab` | `tablepro_rw` / `tablepro_rw_password` | `tablepro_ro` / `tablepro_ro_password` |
| MySQL | `127.0.0.1` | `13306` | `tablepro_lab` | `tablepro_rw` / `tablepro_rw_password` | `tablepro_ro` / `tablepro_ro_password` |
| SQL Server | `127.0.0.1` | `11433` | `tablepro_lab` | `tablepro_rw` / `TableProRw!123` | `tablepro_ro` / `TableProRo!123` |
| ClickHouse | `127.0.0.1` | `18123` | `tablepro_lab` | `tablepro_rw` / `tablepro_rw_password` | `tablepro_ro` / `tablepro_ro_password` |
| MongoDB | `127.0.0.1` | `27017` | `tablepro_lab` | `tablepro_rw` / `tablepro_rw_password` | `tablepro_ro` / `tablepro_ro_password` |
| Redis | `127.0.0.1` | `16379` | `0` | `tablepro_rw` / `tablepro_rw_password` | `tablepro_ro` / `tablepro_ro_password` |

The PostgreSQL and MySQL read-write accounts also own or can access `tablepro_extra`, so use that database to verify switching databases. Redis database `1` is also available for database-switch testing.

## SQLite and DuckDB

Create local fixture files outside the repository so manual data never becomes source state:

```bash
mkdir -p "$HOME/.local/share/tablepro/manual-fixtures"
sqlite3 "$HOME/.local/share/tablepro/manual-fixtures/tablepro-lab.sqlite" \
  'CREATE TABLE IF NOT EXISTS people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, active BOOLEAN NOT NULL); INSERT OR IGNORE INTO people VALUES (1, "Ada Lovelace", 1), (2, "Grace Hopper", 0);'
duckdb "$HOME/.local/share/tablepro/manual-fixtures/tablepro-lab.duckdb" \
  "CREATE TABLE IF NOT EXISTS people (id BIGINT PRIMARY KEY, name VARCHAR NOT NULL, active BOOLEAN NOT NULL); INSERT OR IGNORE INTO people VALUES (1, 'Ada Lovelace', true), (2, 'Grace Hopper', false);"
```

Use the file path as the connection endpoint. DuckDB requires an app build with the `duckdb` Cargo feature.

## Manual checklist

1. Connect each read-write account, list the table or collection, query `people`, insert a row, update it, and delete it.
2. Connect each read-only account, browse and query it, then confirm that an insert is refused.
3. Switch PostgreSQL, MySQL, and Redis between the documented databases and confirm that the app retains the selected database.
4. For MongoDB, query `people` with `find({})`, insert a document, and delete it.
5. For Redis, set, read, and delete a key in both database `0` and database `1`.

Do not use these fixed credentials outside this local disposable fixture.
