//! The connection conformance suite against PostgreSQL.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::{
    ConnectOptions, DatabaseDriver, EditorSessionOptions, LivenessPolicy, NetworkEndpoint, RunEnd, RunOptions,
    TableRef, TlsConfig, UserSql, WorkspaceSettings,
};
use tablepro_driver_postgres::{PgDriver, WORKSPACE_POOL_MAX_SIZE};
use tablepro_test_fixtures::{HbaMode, PostgresFixture, PostgresVersion, ServerVersion};
use tablepro_test_support::FaultTransport;
use tablepro_test_support::conformance::{
    BoundedDdlEngine, ConformanceDdlEngine, ConformanceEngine, ConformanceFailure, DumpEngine, EditorTransactionEngine,
    LargeTableEngine, NativeDump, NetworkConformanceEngine, PooledConformanceEngine, ServerStopEngine,
    TypedConformanceEngine, UnsupportedTypeCase, test_liveness,
};
use tokio_util::sync::CancellationToken;

use crate::support::{EventSink, Events, direct, options_over, password};

pub struct PgEngine {
    fixture: PostgresFixture,
}

fn quoted(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

#[async_trait]
impl ConformanceEngine for PgEngine {
    fn driver() -> Arc<dyn DatabaseDriver> {
        Arc::new(PgDriver)
    }

    async fn start() -> Result<Self, ConformanceFailure> {
        let fixture = PostgresFixture::start(HbaMode::Password)
            .await
            .map_err(ConformanceFailure::setup)?;
        Ok(Self { fixture })
    }

    fn connect_options(&self, settings: WorkspaceSettings, liveness: LivenessPolicy) -> ConnectOptions {
        options_over(
            direct(self.fixture.host(), self.fixture.port(), &liveness),
            password(&self.fixture.password_credentials()),
            self.fixture.database(),
            TlsConfig::disabled(),
            settings,
            liveness,
        )
    }

    fn scratch_table(&self, name: &str) -> TableRef {
        TableRef::new(Some("public".to_owned()), name)
    }

    fn create_scratch_table_sql(&self, table: &TableRef) -> String {
        format!(
            "CREATE TABLE public.{} (id integer PRIMARY KEY, label text NOT NULL)",
            quoted(&table.name)
        )
    }

    fn unbounded_statement_sql(&self, marker: &str) -> String {
        format!("SELECT /* {marker} */ pg_sleep(3600)")
    }

    async fn blocking_statement_sql(&self, marker: &str, hold: Duration) -> Result<String, ConformanceFailure> {
        Ok(format!("SELECT pg_sleep({}) /* {marker} */", hold.as_secs_f64()))
    }

    fn row_source_sql(&self, rows: u64) -> String {
        format!("SELECT generate_series(1, {rows})")
    }
}

#[async_trait]
impl NetworkConformanceEngine for PgEngine {
    async fn faulty_connect_options(
        &self,
        settings: WorkspaceSettings,
        liveness: LivenessPolicy,
    ) -> Result<(ConnectOptions, Arc<FaultTransport>), ConformanceFailure> {
        let endpoint =
            NetworkEndpoint::new(self.fixture.host(), self.fixture.port()).map_err(ConformanceFailure::setup)?;
        let fault = Arc::new(FaultTransport::direct(endpoint, &liveness).map_err(ConformanceFailure::setup)?);
        let options = options_over(
            fault.clone(),
            password(&self.fixture.password_credentials()),
            self.fixture.database(),
            TlsConfig::disabled(),
            settings,
            liveness,
        );
        Ok((options, fault))
    }
}

impl ServerStopEngine for PgEngine {
    /// An editor run reads a row source through its cursor, so the server
    /// shows the FETCH, not the statement and its marker. A FETCH asleep
    /// in `pg_sleep` is the unbounded statement, since each case has the
    /// server to itself.
    fn running_statement_count_sql(&self, marker: &str) -> String {
        format!(
            "SELECT count(*) FROM pg_stat_activity \
             WHERE state = 'active' AND pid <> pg_backend_pid() \
             AND (query LIKE '%{marker}%' \
             OR (query LIKE 'FETCH % FROM tablepro_cursor' AND wait_event = 'PgSleep'))"
        )
    }
}

impl PooledConformanceEngine for PgEngine {
    const WORKSPACE_POOL_MAX_SIZE: usize = WORKSPACE_POOL_MAX_SIZE;
}

impl EditorTransactionEngine for PgEngine {
    fn begin_sql(&self) -> String {
        "BEGIN".to_owned()
    }

    fn commit_sql(&self) -> String {
        "COMMIT".to_owned()
    }
}

impl TypedConformanceEngine for PgEngine {
    fn unsupported_type_cases(&self) -> Vec<UnsupportedTypeCase> {
        let case = |setup: &[&str], declaration: &str, value: &str| UnsupportedTypeCase {
            setup_sql: setup.iter().map(|sql| (*sql).to_owned()).collect(),
            declaration: declaration.to_owned(),
            insert_value_sql: value.to_owned(),
        };
        vec![
            case(&[], "v point", "'(1,2)'::point"),
            case(&[], "v int4range", "'[1,5)'::int4range"),
            case(
                &["CREATE TYPE tp_pair AS (a integer, b text)"],
                "v tp_pair",
                "ROW(1, 'x')::tp_pair",
            ),
            case(
                &["CREATE TYPE tp_mood AS ENUM ('happy', 'sad')"],
                "v tp_mood",
                "'happy'::tp_mood",
            ),
        ]
    }
}

impl BoundedDdlEngine for PgEngine {
    fn schema_change_exceeding_sql(&self, table: &TableRef, duration: Duration) -> String {
        format!(
            "CREATE TABLE public.{} AS SELECT 1 AS id FROM pg_sleep({})",
            quoted(&table.name),
            duration.as_secs_f64()
        )
    }
}

impl LargeTableEngine for PgEngine {
    fn fill_scratch_table_sql(&self, table: &TableRef, rows: u64, label_width: usize) -> Vec<String> {
        let table = format!("public.{}", quoted(&table.name));
        vec![
            format!(
                "INSERT INTO {table} (id, label) \
                 SELECT n, lpad(n::text, {label_width}, '0') FROM generate_series(1, {rows}) AS n"
            ),
            format!("ANALYZE {table}"),
        ]
    }
}

impl ConformanceDdlEngine for PgEngine {
    fn integer_type(&self) -> &'static str {
        "integer"
    }

    fn text_type(&self) -> &'static str {
        "text"
    }

    fn timestamp_type(&self) -> &'static str {
        "timestamp"
    }

    fn current_timestamp_expression(&self) -> &'static str {
        "CURRENT_TIMESTAMP"
    }
}

#[async_trait]
impl DumpEngine for PgEngine {
    async fn empty_database(&self, name: &str) -> Result<ConnectOptions, ConformanceFailure> {
        let liveness = test_liveness();
        let admin = Self::driver()
            .connect(
                self.connect_options(WorkspaceSettings::workspace(false), liveness),
                CancellationToken::new(),
            )
            .await?;
        // CREATE DATABASE refuses a transaction, and the editor runs each
        // statement outside one.
        let session = admin
            .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
            .await?;
        for sql in [
            format!("DROP DATABASE IF EXISTS {} WITH (FORCE)", quoted(name)),
            format!("CREATE DATABASE {}", quoted(name)),
        ] {
            let summary = session
                .run(
                    UserSql::new(sql.as_str()),
                    RunOptions::new(CancellationToken::new()),
                    Box::new(EventSink::new(&Events::default())),
                )
                .await?;
            if summary.end != RunEnd::Completed {
                return Err(ConformanceFailure::setup(format!("`{sql}` ended {:?}", summary.end)));
            }
        }
        session.close().await;
        admin.close().await?;
        Ok(options_over(
            direct(self.fixture.host(), self.fixture.port(), &liveness),
            password(&self.fixture.password_credentials()),
            name,
            TlsConfig::disabled(),
            WorkspaceSettings::workspace(false),
            liveness,
        ))
    }

    /// The child's identity, the parent's serial and the invoice sequence
    /// all stand past the highest key. The trigger appends `;` to every
    /// note it sees, so a trigger made before the rows load shows twice.
    fn dump_fixture(&self) -> Vec<String> {
        [
            "CREATE SCHEMA app",
            "CREATE TYPE app.mood AS ENUM ('sad', 'ok', 'happy')",
            "CREATE DOMAIN app.quantity AS integer CONSTRAINT quantity_positive CHECK (VALUE > 0)",
            "CREATE SEQUENCE app.invoice_no START WITH 1000",
            "CREATE FUNCTION app.mark_note() RETURNS trigger LANGUAGE plpgsql AS $$ \
             BEGIN NEW.note := coalesce(NEW.note, '') || ';'; RETURN NEW; END $$",
            "CREATE FUNCTION app.label(name text, mood app.mood) RETURNS text LANGUAGE sql IMMUTABLE AS $$ \
             SELECT name || ' (' || coalesce(mood::text, 'none') || ')' $$",
            "CREATE TABLE app.parent (id serial PRIMARY KEY, name text NOT NULL UNIQUE, mood app.mood)",
            "CREATE TABLE app.child (\
             id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, \
             parent_id integer NOT NULL REFERENCES app.parent (id), \
             next_id integer REFERENCES app.child (id), \
             invoice integer NOT NULL DEFAULT nextval('app.invoice_no'), \
             qty app.quantity NOT NULL, \
             price numeric(10, 2) NOT NULL CHECK (price >= 0), \
             total numeric GENERATED ALWAYS AS (qty * price) STORED, \
             note text COLLATE \"C\", \
             payload bytea)",
            "CREATE INDEX child_parent_idx ON app.child (parent_id)",
            "CREATE PROCEDURE app.clear_note(target integer) LANGUAGE plpgsql AS $$ \
             BEGIN UPDATE app.child SET note = NULL WHERE id = target; END $$",
            "CREATE TABLE app.reading (taken date NOT NULL, amount integer NOT NULL, PRIMARY KEY (taken, amount)) \
             PARTITION BY RANGE (taken)",
            "CREATE TABLE app.reading_2025 PARTITION OF app.reading FOR VALUES FROM ('2025-01-01') TO ('2026-01-01')",
            "CREATE TABLE app.reading_2026 PARTITION OF app.reading FOR VALUES FROM ('2026-01-01') TO ('2027-01-01')",
            "CREATE TRIGGER child_mark BEFORE INSERT ON app.child FOR EACH ROW EXECUTE FUNCTION app.mark_note()",
            "INSERT INTO app.parent (name, mood) VALUES ('ann', 'happy'), ('bob', 'sad'), ('cy', NULL), ('dee', 'ok')",
            "DELETE FROM app.parent WHERE name = 'dee'",
            r#"INSERT INTO app.child (parent_id, qty, price, note, payload) VALUES
                (1, 2, 1.50, 'it''s "quoted" \ back; and
a new line: ünïcødé', '\x00ff'::bytea),
                (1, 1, 0.25, NULL, NULL),
                (2, 3, 9.99, 'plain', '\xdeadbeef'::bytea),
                (3, 1, 100.00, 'last', NULL)"#,
            "DELETE FROM app.child WHERE id = 4",
            "UPDATE app.child SET next_id = 3 WHERE id = 1",
            "UPDATE app.child SET next_id = 1 WHERE id = 2",
            "INSERT INTO app.reading (taken, amount) VALUES ('2025-03-01', 1), ('2026-07-01', 2), ('2026-08-01', 3)",
            "CREATE VIEW app.parent_labels AS SELECT id, app.label(name, mood) AS label FROM app.parent",
            "CREATE VIEW app.all_labels AS SELECT upper(label) AS label FROM app.parent_labels",
            "CREATE MATERIALIZED VIEW app.child_totals AS \
             SELECT parent_id, sum(total) AS total FROM app.child GROUP BY parent_id",
            "CREATE UNIQUE INDEX child_totals_parent ON app.child_totals (parent_id)",
            "COMMENT ON TABLE app.parent IS 'People; with ''quotes'''",
            "COMMENT ON COLUMN app.child.note IS 'Free text'",
            "COMMENT ON VIEW app.parent_labels IS 'Labels'",
        ]
        .map(str::to_owned)
        .to_vec()
    }

    /// pg_dump 18.6's plain output with its OWNER lines taken out, as
    /// `--no-owner` writes it: `\restrict`, COPY blocks and all.
    /// pg_dump 18 writes `SET transaction_timeout = 0`, which a server
    /// before 17 refuses, as psql with `ON_ERROR_STOP` would show.
    fn native_dump(&self) -> Option<NativeDump> {
        if PostgresVersion::selected().is_ok_and(|version| version.major() < 17) {
            return None;
        }
        let check = |sql: &str, value: &str| (sql.to_owned(), value.to_owned());
        Some(NativeDump {
            file: include_str!("fixtures/pg_dump-18-no-owner.sql"),
            checks: vec![
                check("SELECT count(*) FROM app.child", "4"),
                check("SELECT note FROM app.child WHERE id = 1", r#"it's; a "quote" \ back;"#),
                check("SELECT nextval('app.child_id_seq')", "6"),
                check("SELECT count(*) FROM app.v2", "3"),
                check("SELECT encode(payload, 'hex') FROM app.child WHERE id = 1", "00ff"),
            ],
        })
    }
}

mod suite {
    use super::PgEngine;

    tablepro_test_support::connection_conformance_suite! {
        engine: PgEngine,
        docker: true,
        endpoint: network,
        server_stop: true,
        pool: pooled,
        editor_transactions: true,
        unsupported_types: true,
        bounded_ddl: true,
    }

    tablepro_test_support::ddl_conformance_suite! {
        engine: PgEngine,
        docker: true,
    }

    tablepro_test_support::large_table_conformance_suite! {
        engine: PgEngine,
        docker: true,
    }
}
