#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use std::str::FromStr;
use std::sync::Arc;

use chrono::{DateTime, NaiveDate, NaiveDateTime, NaiveTime, TimeZone, Utc};
use rust_decimal::Decimal;
use serde_json::json;
use uuid::Uuid;

use drivers_postgres::PgDriver;
use tablepro_core::{ConnectOptions, Connection, DatabaseDriver, DriverError, OperationControl, Value};
use testcontainers::ImageExt;
use testcontainers::core::IntoContainerPort;
use testcontainers_modules::postgres::Postgres;
use testcontainers_modules::testcontainers::runners::AsyncRunner;
use tokio_util::sync::CancellationToken;

#[path = "support/wire_round_trip.rs"]
mod wire_round_trip;

#[path = "support/shared_container.rs"]
mod shared_container;

#[path = "support/read_only_session.rs"]
mod read_only_session;

#[path = "support/connection_contracts.rs"]
mod connection_contracts;

#[path = "support/vector_contract.rs"]
mod vector_contract;

#[path = "support/array_contract.rs"]
mod array_contract;

#[path = "support/date_array_csv_import.rs"]
mod date_array_csv_import;

#[path = "support/custom_array_contract.rs"]
mod custom_array_contract;

#[path = "support/range_array_contract.rs"]
mod range_array_contract;

#[path = "support/range_scalar_contract.rs"]
mod range_scalar_contract;

#[path = "support/identity_copy_contract.rs"]
mod identity_copy_contract;

#[path = "support/unsupported_builtin_array_contract.rs"]
mod unsupported_builtin_array_contract;

#[path = "support/binary_array_file_export_contract.rs"]
mod binary_array_file_export_contract;

#[path = "support/time_contract.rs"]
mod time_contract;

#[path = "support/date_contract.rs"]
mod date_contract;

#[path = "support/interval_array_csv_import.rs"]
mod interval_array_csv_import;

#[path = "support/wide_numeric_contract.rs"]
mod wide_numeric_contract;

#[path = "support/interval_contract.rs"]
mod interval_contract;

#[path = "support/query_budget_contract.rs"]
mod query_budget_contract;

#[path = "support/value_contracts.rs"]
mod value_contracts;

#[path = "support/enum_contract.rs"]
mod enum_contract;

#[path = "support/enum_parameter_context_contract.rs"]
mod enum_parameter_context_contract;

#[path = "support/enum_role_context_contract.rs"]
mod enum_role_context_contract;

#[path = "support/enum_type_privilege_contract.rs"]
mod enum_type_privilege_contract;

#[path = "support/quoted_enum_identifier_contract.rs"]
mod quoted_enum_identifier_contract;

#[path = "support/domain_contract.rs"]
mod domain_contract;

#[path = "support/deep_enum_array_operator_parameters.rs"]
mod deep_enum_array_operator_parameters;

#[path = "support/domain_array_file_export_contract.rs"]
mod domain_array_file_export_contract;

#[path = "support/domain_depth_boundary_contract.rs"]
mod domain_depth_boundary_contract;

#[path = "support/domain_uuid_array_contract.rs"]
mod domain_uuid_array_contract;

#[path = "support/domain_array_family_contract.rs"]
mod domain_array_family_contract;

#[path = "support/domain_array_type_contract.rs"]
mod domain_array_type_contract;

#[path = "support/domain_bytea_array_contract.rs"]
mod domain_bytea_array_contract;

#[path = "support/enum_file_export_contract.rs"]
mod enum_file_export_contract;

#[path = "support/disconnection.rs"]
mod disconnection;

#[path = "support/rollback_failure.rs"]
mod rollback_failure;

#[path = "../../shared/server_restart.rs"]
mod server_restart;

#[path = "../../shared/connect_refusal.rs"]
mod connect_refusal;

#[tokio::test]
async fn an_unavailable_postgres_server_is_classified_as_connection_refused() {
    connect_refusal::assert_connection_refused(&PgDriver)
        .await
        .expect("PostgreSQL setup refusal remains distinct from established disconnect");
}

async fn start_pg() -> (shared_container::TestDatabase, ConnectOptions) {
    shared_container::start_pg().await
}

async fn connect(opts: ConnectOptions) -> Box<dyn Connection> {
    PgDriver.connect(opts).await.expect("connect")
}

fn no_timeout() -> OperationControl {
    OperationControl::new(CancellationToken::new(), None)
}

async fn session_value(session: &mut Box<dyn tablepro_core::Session>, sql: &str) -> Value {
    let result = session.query_params_controlled(sql, &[], &no_timeout()).await.unwrap();
    result.rows[0][0].clone()
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_session_keeps_settings_temp_tables_and_its_transaction_between_statements() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute("CREATE TABLE ledger (id int)").await.unwrap();
    let mut session = conn.open_session().await.unwrap();
    let control = no_timeout();

    for sql in [
        "SET search_path TO pg_catalog, public",
        "CREATE TEMP TABLE scratch (n int)",
        "INSERT INTO scratch VALUES (7)",
    ] {
        session.query_params_controlled(sql, &[], &control).await.unwrap();
    }
    assert_eq!(
        session_value(&mut session, "SELECT current_setting('search_path')").await,
        Value::Text("pg_catalog, public".into())
    );
    assert_eq!(
        session_value(&mut session, "SELECT n FROM scratch").await,
        Value::Int(7)
    );

    for sql in ["BEGIN", "INSERT INTO public.ledger VALUES (1)", "ROLLBACK"] {
        session.query_params_controlled(sql, &[], &control).await.unwrap();
    }
    assert_eq!(
        session_value(&mut session, "SELECT count(*)::bigint FROM public.ledger").await,
        Value::Int(0)
    );

    session.close().await.unwrap();
    let after = conn
        .query("SELECT count(*)::bigint FROM pg_tables WHERE tablename = 'scratch'")
        .await
        .unwrap();
    assert_eq!(after.rows, vec![vec![Value::Int(0)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn open_sessions_do_not_take_connections_from_the_shared_pool() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    let mut sessions = Vec::new();
    for _ in 0..6 {
        sessions.push(conn.open_session().await.unwrap());
    }

    let result = conn.query("SELECT 1").await.unwrap();

    assert_eq!(result.rows, vec![vec![Value::Int(1)]]);
    for session in sessions {
        session.close().await.unwrap();
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_cancelled_session_statement_stops_on_the_server_and_keeps_the_session() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts.clone()).await;
    let observer = connect(opts).await;
    let mut session = conn.open_session().await.unwrap();
    session
        .query_params_controlled("SET application_name TO 'kept'", &[], &no_timeout())
        .await
        .unwrap();
    let token = CancellationToken::new();
    let control = OperationControl::new(token.clone(), None);
    let cancel = token.clone();
    let observed = tokio::spawn(async move {
        disconnection::wait_for_tagged_query(observer.as_ref(), "bookie_session_cancel", true).await;
        cancel.cancel();
    });

    let error = session
        .query_params_controlled("SELECT pg_sleep(30) /* bookie_session_cancel */", &[], &control)
        .await
        .unwrap_err();
    observed.await.unwrap();

    assert!(matches!(error, DriverError::Cancelled), "{error:?}");
    assert!(session.is_usable());
    assert_eq!(
        session_value(&mut session, "SELECT current_setting('application_name')").await,
        Value::Text("kept".into())
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_bare_begin_does_not_leave_a_pooled_session_inside_a_transaction() {
    let (_c, mut opts) = start_pg().await;
    opts.application_name = Some("pool-probe".into());
    let conn = connect(opts).await;

    let _ = conn.execute("BEGIN").await;
    let _ = conn.query("SELECT 1").await;

    let idle_in_transaction = conn
        .query(
            "SELECT count(*)::bigint FROM pg_stat_activity \
             WHERE application_name = 'pool-probe' AND state = 'idle in transaction'",
        )
        .await
        .unwrap();
    assert_eq!(idle_in_transaction.rows, vec![vec![Value::Int(0)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_column_collation_is_read_and_survives_a_type_change() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute("CREATE TABLE collated (label varchar(40) COLLATE \"C\", plain text)")
        .await
        .unwrap();

    let columns = conn.fetch_columns(None, "collated").await.unwrap();
    assert_eq!(columns[0].collation.as_deref(), Some("C"));
    assert_eq!(columns[1].collation, None);

    let mut draft = tablepro_core::sql_ddl::DraftColumn::from_info(columns[0].clone());
    draft.data_type = "character varying(80)".into();
    for statement in tablepro_core::sql_ddl::build_alter_column("postgres", None, "collated", &draft).unwrap() {
        conn.execute(&statement).await.unwrap();
    }

    let altered = conn.fetch_columns(None, "collated").await.unwrap();
    assert_eq!(altered[0].data_type, "character varying(80)");
    assert_eq!(altered[0].collation.as_deref(), Some("C"));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn the_session_reports_the_application_name_it_was_given() {
    let (_c, mut opts) = start_pg().await;
    opts.application_name = Some("BookiE".into());
    let conn = connect(opts).await;

    let result = conn.query("SELECT current_setting('application_name')").await.unwrap();

    assert_eq!(result.rows, vec![vec![Value::Text("BookiE".into())]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn catalog_objects_are_listed_per_kind_and_filtered_by_schema() {
    use tablepro_core::CatalogObjectKind as Kind;
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    for statement in [
        "CREATE SCHEMA \"odd'schema\"",
        "CREATE TABLE \"odd'schema\".events (id serial PRIMARY KEY, happened timestamptz)",
        "CREATE FUNCTION \"odd'schema\".touch() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$",
        "CREATE TRIGGER events_touch BEFORE INSERT ON \"odd'schema\".events FOR EACH ROW EXECUTE FUNCTION \"odd'schema\".touch()",
        "CREATE PROCEDURE \"odd'schema\".archive(days int) LANGUAGE sql AS $$ SELECT 1 $$",
        "CREATE SEQUENCE \"odd'schema\".ticket_numbers AS bigint",
        "CREATE TYPE \"odd'schema\".mood AS ENUM ('ok', 'sad')",
        "CREATE TYPE \"odd'schema\".point2 AS (x int, y int)",
        "CREATE DOMAIN \"odd'schema\".positive AS int CHECK (VALUE > 0)",
        "CREATE TYPE \"odd'schema\".hours AS RANGE (subtype = int4)",
        "CREATE ROLE report_reader LOGIN",
        "CREATE FUNCTION public.elsewhere() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$",
        "GRANT SELECT, INSERT ON \"odd'schema\".events TO report_reader",
    ] {
        conn.execute(statement)
            .await
            .unwrap_or_else(|e| panic!("{statement}: {e}"));
    }
    let listed = |kind| {
        let conn = &conn;
        async move {
            let objects = conn.list_objects(kind, Some("odd'schema")).await.unwrap();
            objects
                .into_iter()
                .map(|o| (o.name, o.detail.unwrap_or_default()))
                .collect::<Vec<_>>()
        }
    };

    let routines = listed(Kind::Routine).await;
    assert_eq!(
        routines,
        vec![
            ("archive".into(), "procedure(IN days integer)".into()),
            ("touch".into(), "function()".into())
        ]
    );
    assert!(!routines.iter().any(|(name, _)| name == "elsewhere"));
    assert_eq!(
        listed(Kind::Trigger).await,
        vec![("events_touch".into(), "on events".into())]
    );
    let sequences = listed(Kind::Sequence).await;
    assert!(
        sequences.contains(&("ticket_numbers".into(), "bigint".into())),
        "{sequences:?}"
    );
    assert!(sequences.iter().any(|(name, _)| name == "events_id_seq"));
    let types = listed(Kind::Type).await;
    for expected in [
        ("hours", "range"),
        ("mood", "enum"),
        ("point2", "composite"),
        ("positive", "domain over integer"),
    ] {
        assert!(types.contains(&(expected.0.into(), expected.1.into())), "{types:?}");
    }
    assert!(
        !types.iter().any(|(name, _)| name == "events"),
        "a table row type is not a composite type"
    );

    let extensions = conn.list_objects(Kind::Extension, Some("odd'schema")).await.unwrap();
    assert!(extensions.iter().any(|e| e.name == "plpgsql"), "{extensions:?}");
    let roles = conn.list_objects(Kind::Role, None).await.unwrap();
    let reader = roles.iter().find(|r| r.name == "report_reader").unwrap();
    assert_eq!(reader.detail.as_deref(), Some("login"));
    assert!(!roles.iter().any(|r| r.name.starts_with("pg_")));

    let grants = listed(Kind::Grant).await;
    assert!(
        grants.contains(&("events".into(), "report_reader: INSERT, SELECT".into())),
        "{grants:?}"
    );
    assert!(
        grants
            .iter()
            .any(|(name, detail)| name == "events" && detail.starts_with("postgres: ")),
        "{grants:?}"
    );

    let every_schema = conn.list_objects(Kind::Routine, None).await.unwrap();
    assert!(every_schema.iter().any(|o| o.name == "elsewhere"));
    assert!(!every_schema.iter().any(|o| o.schema.as_deref() == Some("pg_catalog")));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn indexes_report_expression_keys_predicates_and_leave_out_included_columns() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    for statement in [
        "CREATE TABLE people (id int PRIMARY KEY, email text, \"Nick Name\" text, deleted_at timestamptz)",
        "CREATE INDEX people_lower_email ON people (lower(email))",
        "CREATE UNIQUE INDEX people_live_email ON people (email, \"Nick Name\") WHERE deleted_at IS NULL",
        "CREATE INDEX people_email_covering ON people (email) INCLUDE (deleted_at)",
    ] {
        conn.execute(statement).await.unwrap();
    }

    let indexes = conn.fetch_indexes(None, "people").await.unwrap();
    let by_name = |name: &str| {
        indexes
            .iter()
            .find(|i| i.name == name)
            .unwrap_or_else(|| panic!("{indexes:?}"))
    };

    assert_eq!(by_name("people_lower_email").columns, vec!["lower(email)".to_string()]);
    assert_eq!(by_name("people_lower_email").predicate, None);
    let partial = by_name("people_live_email");
    assert_eq!(partial.columns, vec!["email".to_string(), "Nick Name".to_string()]);
    assert_eq!(partial.predicate.as_deref(), Some("deleted_at IS NULL"));
    assert_eq!(by_name("people_email_covering").columns, vec!["email".to_string()]);
    assert!(by_name("people_pkey").primary);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn formatting_preserves_server_results_for_significant_whitespace() {
    use tablepro_core::sql_syntax::{SqlGrammar, script::LexicalSettings};
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    for source in [
        "SELECT 'a'\n'b'",
        r"SELECT U&'d\0061t'",
        "SELECT 1 + 2 AS total",
        "SELECT E'a\\nb'",
    ] {
        let formatted = tablepro_core::sql_format::format_script(
            source,
            SqlGrammar::PostgreSql,
            LexicalSettings::default_for(SqlGrammar::PostgreSql),
        );
        let original = connection.query(source).await.expect("original expression");
        let result = connection.query(&formatted).await.expect("formatted expression");
        assert_eq!(original.rows, result.rows, "{source:?} became {formatted:?}");
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn connect_list_tables_and_pk_detection() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;

    conn.execute(
        "CREATE TABLE pk_demo (
            id serial PRIMARY KEY,
            name text NOT NULL,
            note text
        )",
    )
    .await
    .unwrap();
    conn.execute("INSERT INTO pk_demo (name, note) VALUES ('a', NULL), ('b', 'second')")
        .await
        .unwrap();

    let tables = conn.list_tables().await.unwrap();
    assert!(tables.iter().any(|t| t.name == "pk_demo"));

    let cols = conn.fetch_columns(None, "pk_demo").await.unwrap();
    assert_eq!(cols.len(), 3);
    let id_col = cols.iter().find(|c| c.name == "id").unwrap();
    assert!(id_col.primary_key, "id must be detected as primary key");
    assert!(!id_col.nullable);
    let note_col = cols.iter().find(|c| c.name == "note").unwrap();
    assert!(!note_col.primary_key);
    assert!(note_col.nullable);

    let result = conn.fetch_rows(None, "pk_demo", 0, 100).await.unwrap();
    assert_eq!(result.rows.len(), 2);
    assert!(!result.truncated);

    conn.execute("CREATE VIEW pk_demo_names AS SELECT name FROM pk_demo")
        .await
        .unwrap();
    let views = conn.list_views().await.unwrap();
    assert!(
        views.iter().any(|view| view.name == "pk_demo_names"),
        "list_views must return the created view"
    );
    let view_rows = conn.fetch_rows(None, "pk_demo_names", 0, 100).await.unwrap();
    assert_eq!(view_rows.rows.len(), 2);

    conn.execute("CREATE MATERIALIZED VIEW pk_demo_snapshot AS SELECT id, name FROM pk_demo")
        .await
        .unwrap();
    let views = conn.list_views().await.unwrap();
    assert!(
        views.iter().any(|view| view.name == "pk_demo_snapshot"),
        "list_views must return the materialized view: {views:?}"
    );
    let tables = conn.list_tables().await.unwrap();
    assert!(!tables.iter().any(|table| table.name == "pk_demo_snapshot"));
    let snapshot_columns = conn.fetch_columns(None, "pk_demo_snapshot").await.unwrap();
    assert_eq!(snapshot_columns.len(), 2);
    let snapshot_rows = conn.fetch_rows(None, "pk_demo_snapshot", 0, 100).await.unwrap();
    assert_eq!(snapshot_rows.rows.len(), 2);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_roundtrip_all_types() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;

    conn.execute(
        "CREATE TABLE roundtrip (
            id serial PRIMARY KEY,
            b bool,
            i2 smallint,
            i4 integer,
            i8 bigint,
            f4 real,
            f8 double precision,
            num numeric(20,5),
            t text,
            bytes bytea,
            d date,
            tm time,
            dt timestamp,
            tz timestamptz,
            u uuid,
            j jsonb,
            nullable_text text
        )",
    )
    .await
    .unwrap();

    let date = NaiveDate::from_ymd_opt(2024, 6, 15).unwrap();
    let time = NaiveTime::from_hms_opt(13, 45, 30).unwrap();
    let dt = NaiveDateTime::new(date, time);
    let tz: DateTime<Utc> = Utc.with_ymd_and_hms(2024, 6, 15, 13, 45, 30).unwrap();
    let uuid = Uuid::from_str("550e8400-e29b-41d4-a716-446655440000").unwrap();
    let dec = Decimal::from_str("12345.67890").unwrap();
    let json_val = json!({"k": [1, 2, 3], "nested": {"flag": true}});

    let params = vec![
        Value::Bool(true),
        Value::Int(123),
        Value::Int(2_000_000_000),
        Value::Int(9_000_000_000_000_000_000),
        Value::Float(1.5_f64),
        Value::Float(std::f64::consts::PI),
        Value::Decimal(dec),
        Value::Text("hello\nworld".into()),
        Value::Bytes(vec![0xde, 0xad, 0xbe, 0xef]),
        Value::Date(date),
        Value::Time(time),
        Value::DateTime(dt),
        Value::TimestampTz(tz),
        Value::Uuid(uuid),
        Value::Json(json_val.clone()),
        Value::Null,
    ];

    let res = conn
        .execute_params(
            "INSERT INTO roundtrip
             (b, i2, i4, i8, f4, f8, num, t, bytes, d, tm, dt, tz, u, j, nullable_text)
             VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)",
            &params,
        )
        .await
        .unwrap();
    assert_eq!(res.rows_affected, 1);

    let q = conn
        .query(
            "SELECT b, i2, i4, i8, f4, f8, num, t, bytes, d, tm, dt, tz, u, j, nullable_text
             FROM roundtrip ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(q.rows.len(), 1);
    let row = &q.rows[0];

    assert!(matches!(row[0], Value::Bool(true)));
    assert!(matches!(row[1], Value::Int(123)));
    assert!(matches!(row[2], Value::Int(2_000_000_000)));
    assert!(matches!(row[3], Value::Int(9_000_000_000_000_000_000)));
    match &row[4] {
        Value::Float(f) => assert!((*f - 1.5).abs() < 1e-5),
        v => panic!("expected float, got {v:?}"),
    }
    match &row[5] {
        Value::Float(f) => assert!((*f - std::f64::consts::PI).abs() < 1e-9),
        v => panic!("expected float, got {v:?}"),
    }
    match &row[6] {
        Value::Decimal(d) => assert_eq!(d.to_string(), "12345.67890"),
        v => panic!("expected decimal, got {v:?}"),
    }
    assert_eq!(row[7], Value::Text("hello\nworld".into()));
    assert_eq!(row[8], Value::Bytes(vec![0xde, 0xad, 0xbe, 0xef]));
    assert_eq!(row[9], Value::Date(date));
    assert_eq!(row[10], Value::Time(time));
    assert_eq!(row[11], Value::DateTime(dt));
    assert_eq!(row[12], Value::TimestampTz(tz));
    assert_eq!(row[13], Value::Uuid(uuid));
    match &row[14] {
        Value::Json(v) => assert_eq!(v, &json_val),
        v => panic!("expected json, got {v:?}"),
    }
    assert_eq!(row[15], Value::Null);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn pagination_and_truncated_flag() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;

    conn.execute("CREATE TABLE big (i int PRIMARY KEY)").await.unwrap();
    let mut sql = String::from("INSERT INTO big (i) VALUES ");
    for i in 0..50 {
        if i > 0 {
            sql.push(',');
        }
        sql.push_str(&format!("({i})"));
    }
    conn.execute(&sql).await.unwrap();

    let page = conn.fetch_rows(None, "big", 10, 5).await.unwrap();
    assert_eq!(page.rows.len(), 5);
    let firsts: Vec<i64> = page
        .rows
        .iter()
        .map(|r| match r[0] {
            Value::Int(i) => i,
            _ => panic!(),
        })
        .collect();
    assert_eq!(firsts, vec![10, 11, 12, 13, 14]);

    let q = conn.query("SELECT i FROM big ORDER BY i").await.unwrap();
    assert_eq!(q.rows.len(), 50);
    assert!(!q.truncated);
}

async fn assert_capped_and_server_stopped(observer: &dyn Connection, result: QueryResultProbe, tag: &str) {
    let QueryResultProbe {
        truncated,
        rows,
        elapsed,
    } = result;
    assert!(truncated, "{rows} rows in {elapsed:?}");
    assert!(rows <= tablepro_core::MAX_QUERY_ROWS);
    assert!(
        elapsed < std::time::Duration::from_secs(30),
        "{rows} rows in {elapsed:?}"
    );
    let still_running = format!(
        "SELECT count(*) FROM pg_stat_activity WHERE state = 'active' AND query LIKE '%{tag}%' AND pid <> pg_backend_pid()"
    );
    let mut running = i64::MAX;
    for _ in 0..30 {
        running = match observer.query(&still_running).await.unwrap().rows[0][0] {
            Value::Int(count) => count,
            ref other => panic!("{other:?}"),
        };
        if running == 0 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
    assert_eq!(running, 0, "the server kept producing rows after the cap");
}

struct QueryResultProbe {
    truncated: bool,
    rows: usize,
    elapsed: std::time::Duration,
}

const UNBOUNDED_SQL: &str = "SELECT i, repeat('x', 8) AS pad FROM (SELECT generate_series(1::bigint, 4000000000::bigint) AS i) AS g /* bookie_pg_row_cap */";

#[tokio::test]
#[ignore = "requires docker"]
async fn an_unbounded_query_is_cut_at_the_cap_and_the_server_stops_producing() {
    let (_c, opts) = start_pg().await;
    let observer = connect(opts.clone()).await;
    let conn = connect(opts).await;
    let started = std::time::Instant::now();
    let result = conn.query(UNBOUNDED_SQL).await.unwrap();
    let probe = QueryResultProbe {
        truncated: result.truncated,
        rows: result.rows.len(),
        elapsed: started.elapsed(),
    };
    assert_capped_and_server_stopped(observer.as_ref(), probe, "bookie_pg_row_cap").await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_controlled_unbounded_query_returns_the_capped_rows_instead_of_timing_out() {
    let (_c, opts) = start_pg().await;
    let observer = connect(opts.clone()).await;
    let conn = connect(opts).await;
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    let started = std::time::Instant::now();
    let result = conn.query_params_controlled(UNBOUNDED_SQL, &[], &control).await;
    let elapsed = started.elapsed();
    let result = result.unwrap_or_else(|error| panic!("{error:?} after {elapsed:?}"));
    let probe = QueryResultProbe {
        truncated: result.truncated,
        rows: result.rows.len(),
        elapsed,
    };
    assert_capped_and_server_stopped(observer.as_ref(), probe, "bookie_pg_row_cap").await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_session_stays_usable_after_a_capped_result() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    let mut session = conn.open_session().await.unwrap();
    session
        .query_params_controlled("CREATE TEMP TABLE kept AS SELECT 7 AS n", &[], &no_timeout())
        .await
        .ok();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    let capped = session
        .query_params_controlled(UNBOUNDED_SQL, &[], &control)
        .await
        .unwrap();
    assert!(capped.truncated);
    assert_eq!(session_value(&mut session, "SELECT n FROM kept").await, Value::Int(7));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_result_delivery_keeps_zero_row_metadata_duplicate_names_and_order() {
    let (_container, opts) = start_pg().await;
    let conn = connect(opts).await;

    let empty = conn
        .query("SELECT 9007199254740993::numeric AS amount, 'payload'::text AS label WHERE false")
        .await
        .unwrap();
    assert!(empty.rows.is_empty());
    assert!(!empty.truncated);
    assert_eq!(
        empty
            .columns
            .iter()
            .map(|column| column.name.as_str())
            .collect::<Vec<_>>(),
        vec!["amount", "label"]
    );
    assert_eq!(
        empty
            .columns
            .iter()
            .map(|column| column.data_type.as_str())
            .collect::<Vec<_>>(),
        vec!["numeric", "text"]
    );

    let empty_with_params = conn
        .query_params(
            "SELECT $1::bigint AS amount, $2::text AS label WHERE false",
            &[Value::Int(9007199254740993), Value::Text("payload".into())],
        )
        .await
        .unwrap();
    assert!(empty_with_params.rows.is_empty());
    assert_eq!(
        empty_with_params
            .columns
            .iter()
            .map(|column| (column.name.as_str(), column.data_type.as_str()))
            .collect::<Vec<_>>(),
        vec![("amount", "int8"), ("label", "text")]
    );

    let duplicate_names = conn
        .query(
            "SELECT 17::bigint AS duplicate, 'second'::text AS duplicate \
             UNION ALL SELECT 23::bigint, 'fourth'::text",
        )
        .await
        .unwrap();
    assert_eq!(
        duplicate_names
            .columns
            .iter()
            .map(|column| column.name.as_str())
            .collect::<Vec<_>>(),
        vec!["duplicate", "duplicate"]
    );
    assert_eq!(
        duplicate_names.rows,
        vec![
            vec![Value::Int(17), Value::Text("second".into())],
            vec![Value::Int(23), Value::Text("fourth".into())],
        ]
    );
    assert!(!duplicate_names.truncated);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn bad_sql_returns_query_error() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;

    let err = conn.query("SELECT * FROM no_such_table").await.unwrap_err();
    let msg = format!("{err}");
    assert!(
        msg.to_lowercase().contains("no_such_table") || msg.to_lowercase().contains("relation"),
        "expected error to mention missing relation, got: {msg}"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_numeric_digits_scale_and_special_values_survive_decoding() {
    let (_container, opts) = start_pg().await;
    let conn = connect(opts).await;
    let mut session = conn.open_session().await.unwrap();
    for input in [
        "1234567890123456789012345678901234567890",
        "-1234567890123456789012345678901234567890.0012300",
        "0.123456789012345678901234567891",
        "-0.123456789012345678901234567895",
        "99999999999999999999.99999999",
        "1.23000000",
        "0.00000000",
        "1e1000",
        "1e-1000",
        "NaN",
        "Infinity",
        "-Infinity",
    ] {
        let literal = tablepro_core::sql_literal::render_sql_literal("postgres", &Value::Text(input.into())).unwrap();
        let sql = format!("SELECT {literal}::numeric AS value, ({literal}::numeric)::text AS expected");
        let direct = conn.query(&sql).await.unwrap();
        let bound = conn
            .query_params(
                "SELECT $1::text::numeric AS value, ($1::text::numeric)::text AS expected",
                &[Value::Text(input.into())],
            )
            .await
            .unwrap();
        let session_result = session.query_params_controlled(&sql, &[], &no_timeout()).await.unwrap();
        for result in [direct, bound, session_result] {
            let actual = match &result.rows[0][0] {
                Value::Decimal(value) => value.to_string(),
                Value::Text(value) => value.clone(),
                other => panic!("{input}: unexpected {other:?}"),
            };
            assert_eq!(Value::Text(actual), result.rows[0][1], "{input}");
        }
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn non_null_decode_failures_are_not_returned_as_null() {
    let (_container, opts) = start_pg().await;
    let conn = connect(opts).await;
    let result = conn
        .query("SELECT NULL::numeric, NULL::int[], NULL::date, 42::int")
        .await
        .unwrap();
    assert_eq!(
        result.rows[0],
        vec![Value::Null, Value::Null, Value::Null, Value::Int(42)]
    );
    for expression in [
        "'5874897-12-31'::date",
        "'280000-01-01'::timestamp",
        "'280000-01-01 00:00:00+00'::timestamptz",
    ] {
        let result = conn
            .query(&format!("SELECT {expression}, ({expression})::text"))
            .await
            .unwrap();
        assert!(
            matches!(result.rows[0][0], Value::Text(_)),
            "{expression}: {:?}",
            result.rows[0][0]
        );
        assert_eq!(result.rows[0][0], result.rows[0][1], "{expression}");
    }
    // A single undecodable cell degrades to `Value::Undecodable` instead of
    // aborting the whole result set (or silently becoming NULL): the rest
    // of the row, and other rows in the same result, still come back.
    {
        let sql = "SELECT ARRAY[int4range(1, 3)]";
        let result = conn.query(sql).await.unwrap_or_else(|e| panic!("{sql}: {e}"));
        assert!(
            matches!(result.rows[0][0], Value::Undecodable(_)),
            "{sql}: expected an undecodable cell, got {:?}",
            result.rows[0][0]
        );
    }
    {
        let sql = "SELECT ARRAY[int4range(1, 3)], 42::int";
        let result = conn.query(sql).await.unwrap();
        assert!(matches!(result.rows[0][0], Value::Undecodable(_)));
        assert_eq!(result.rows[0][1], Value::Int(42));
    }
    assert_eq!(conn.query("SELECT 42::int").await.unwrap().rows[0][0], Value::Int(42));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn activity_duration_types_decode_as_text() {
    let (_container, opts) = start_pg().await;
    let conn = connect(opts).await;
    let result = conn
        .query(
            "SELECT INTERVAL '1 hour 2 minutes 3 seconds', \
                    INTERVAL '3 days', \
                    NULL::interval, \
                    '192.0.2.1'::inet, \
                    '192.0.2.0/24'::cidr, \
                    '2001:db8::1'::inet, \
                    '0/16B3748'::pg_lsn, \
                    now() - query_start \
             FROM pg_stat_activity \
             WHERE pid = pg_backend_pid()",
        )
        .await
        .expect("activity types must decode");
    assert_eq!(result.rows[0][0], Value::Text("01:02:03".into()));
    assert_eq!(result.rows[0][1], Value::Text("3 days".into()));
    assert_eq!(result.rows[0][2], Value::Null);
    assert_eq!(result.rows[0][3], Value::Text("192.0.2.1".into()));
    assert_eq!(result.rows[0][4], Value::Text("192.0.2.0/24".into()));
    assert_eq!(result.rows[0][5], Value::Text("2001:db8::1".into()));
    assert_eq!(result.rows[0][6], Value::Text("0/16B3748".into()));
    assert!(
        matches!(&result.rows[0][7], Value::Text(value) if !value.is_empty()),
        "session duration must remain a readable interval, got {:?}",
        result.rows[0][7]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_column_comment_round_trips_and_a_table_comment_does_not_leak_into_it() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE TABLE comment_demo (id integer, label text)")
        .await
        .unwrap();
    connection
        .execute("COMMENT ON TABLE comment_demo IS 'the whole table'")
        .await
        .unwrap();
    connection
        .execute("COMMENT ON COLUMN comment_demo.label IS 'what the row is called'")
        .await
        .unwrap();

    let columns = connection.fetch_columns(None, "comment_demo").await.unwrap();
    let id = columns.iter().find(|c| c.name == "id").unwrap();
    let label = columns.iter().find(|c| c.name == "label").unwrap();
    assert_eq!(label.comment.as_deref(), Some("what the row is called"));
    assert_eq!(id.comment, None, "the table comment must not reach a column");

    connection
        .execute("COMMENT ON COLUMN comment_demo.label IS NULL")
        .await
        .unwrap();
    let cleared = connection.fetch_columns(None, "comment_demo").await.unwrap();
    assert_eq!(cleared.iter().find(|c| c.name == "label").unwrap().comment, None);
}

async fn column_defaults(conn: &dyn Connection, table: &str) -> Vec<(String, Option<String>)> {
    let columns = conn.fetch_columns(None, table).await.unwrap();
    columns.into_iter().map(|c| (c.name, c.default_value)).collect()
}

#[tokio::test]
#[ignore = "requires docker"]
async fn fetched_defaults_keep_no_default_null_empty_and_literal_apart_and_reapply_exactly() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute(
        "CREATE TABLE defaults_kept (id int PRIMARY KEY, \
         bare text, \
         explicit_null text DEFAULT NULL, \
         blank text DEFAULT '', \
         word text DEFAULT 'it''s', \
         amount int DEFAULT 0, \
         lowered text DEFAULT lower('X'), \
         tags text[] DEFAULT '{}'::text[])",
    )
    .await
    .unwrap();
    let expected: Vec<(String, Option<String>)> = [
        ("id", None),
        ("bare", None),
        ("explicit_null", None),
        ("blank", Some("''")),
        ("word", Some("'it''s'")),
        ("amount", Some("0")),
        ("lowered", Some("lower('X'::text)")),
        ("tags", Some("'{}'")),
    ]
    .into_iter()
    .map(|(name, default)| (name.to_string(), default.map(str::to_string)))
    .collect();
    assert_eq!(column_defaults(conn.as_ref(), "defaults_kept").await, expected);

    let columns = conn.fetch_columns(None, "defaults_kept").await.unwrap();
    for info in columns.into_iter().filter(|c| c.name != "id") {
        let mut copy = tablepro_core::sql_ddl::DraftColumn::from_info(info.clone());
        copy.original = None;
        copy.name = format!("{}_copy", info.name);
        for statement in tablepro_core::sql_ddl::build_add_column("postgres", None, "defaults_kept", &copy).unwrap() {
            conn.execute(&statement).await.unwrap();
        }
        let mut draft = tablepro_core::sql_ddl::DraftColumn::from_info(info);
        draft.nullable = false;
        if draft.default_value.is_none() {
            continue;
        }
        for statement in tablepro_core::sql_ddl::build_alter_column("postgres", None, "defaults_kept", &draft).unwrap()
        {
            conn.execute(&statement).await.unwrap();
        }
    }

    let after = column_defaults(conn.as_ref(), "defaults_kept").await;
    for (name, default) in &expected {
        assert!(
            after.contains(&(name.clone(), default.clone())),
            "{name} kept {default:?}: {after:?}"
        );
    }
    conn.execute("INSERT INTO defaults_kept (id) VALUES (1)").await.unwrap();
    let pairs = conn
        .query(
            "SELECT blank IS NOT DISTINCT FROM blank_copy, word IS NOT DISTINCT FROM word_copy, \
             explicit_null IS NOT DISTINCT FROM explicit_null_copy, bare_copy IS NULL, \
             amount IS NOT DISTINCT FROM amount_copy, lowered IS NOT DISTINCT FROM lowered_copy, \
             tags IS NOT DISTINCT FROM tags_copy, blank = '' \
             FROM defaults_kept WHERE id = 1",
        )
        .await
        .unwrap();
    assert_eq!(pairs.rows[0], vec![Value::Bool(true); 8]);
}

async fn notes_in(conn: &dyn Connection, table: &str) -> Vec<String> {
    let rows = conn.query(&format!("SELECT note FROM {table}")).await.unwrap();
    let mut notes: Vec<String> = rows
        .rows
        .iter()
        .map(|row| match &row[0] {
            Value::Text(text) => text.clone(),
            other => panic!("note must be text, got {other:?}"),
        })
        .collect();
    notes.sort();
    notes
}

async fn grid_edits_and_deletes_only_the_keyed_row(conn: &dyn Connection, driver_id: &str, table: &str) {
    let columns = conn.fetch_columns(None, table).await.unwrap();
    let note = columns.iter().position(|c| c.name == "note").unwrap();
    let rows = conn.fetch_rows(None, table, 0, 10).await.unwrap();
    let target = rows
        .rows
        .iter()
        .find(|row| row[note] == Value::Text("target".into()))
        .unwrap();
    let pk_values: Vec<Value> = columns
        .iter()
        .zip(target)
        .filter(|(column, _)| column.primary_key)
        .map(|(_, value)| value.clone())
        .collect();
    assert!(!pk_values.is_empty(), "{table} must report its primary key");
    let before = notes_in(conn, table).await;
    let others: Vec<String> = before.iter().filter(|n| *n != "target").cloned().collect();

    let update = tablepro_core::sql_dialect::build_keyed_update(
        driver_id,
        None,
        table,
        &columns,
        &[(note, Value::Text("edited".into()))],
        &pk_values,
    )
    .unwrap();
    assert_eq!(
        conn.execute_in_transaction(&[update]).await.unwrap(),
        vec![1],
        "{table} update"
    );
    let mut expected = others.clone();
    expected.insert(0, "edited".to_string());
    assert_eq!(
        notes_in(conn, table).await,
        expected,
        "{table} update touched only the keyed row"
    );

    let delete = tablepro_core::sql_dialect::build_keyed_delete(driver_id, None, table, &columns, &pk_values).unwrap();
    assert_eq!(
        conn.execute_in_transaction(&[delete]).await.unwrap(),
        vec![1],
        "{table} delete"
    );
    assert_eq!(
        notes_in(conn, table).await,
        others,
        "{table} delete removed only the keyed row"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn grid_row_edits_find_rows_by_uuid_composite_and_wide_bigint_keys() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    for sql in [
        "CREATE TABLE keyed_uuid (id uuid PRIMARY KEY, note text)",
        "INSERT INTO keyed_uuid VALUES ('6f1c2a8e-3b4d-4e5f-8a9b-0c1d2e3f4a5b', 'target'), \
         ('6f1c2a8e-3b4d-4e5f-8a9b-0c1d2e3f4a5c', 'other')",
        "CREATE TABLE keyed_composite (tenant int, code text, note text, PRIMARY KEY (tenant, code))",
        "INSERT INTO keyed_composite VALUES (1, 'a', 'target'), (1, 'b', 'other'), (2, 'a', 'other')",
        "CREATE TABLE keyed_bigint (id bigint PRIMARY KEY, note text)",
        "INSERT INTO keyed_bigint VALUES (9007199254740993, 'target'), (9007199254740992, 'other')",
    ] {
        conn.execute(sql).await.unwrap();
    }
    for table in ["keyed_uuid", "keyed_composite", "keyed_bigint"] {
        grid_edits_and_deletes_only_the_keyed_row(conn.as_ref(), "postgres", table).await;
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn binary_sql_exports_round_trip_null_empty_and_every_byte() {
    let (_container, options) = start_pg().await;
    let conn = connect(options).await;
    conn.execute("CREATE TABLE binary_exports (id INTEGER, payload BYTEA)")
        .await
        .unwrap();
    let columns = conn.fetch_columns(None, "binary_exports").await.unwrap();
    let values = [Value::Null, Value::Bytes(vec![]), Value::Bytes((0u8..=255).collect())];
    for (id, value) in values.iter().enumerate() {
        let statement = tablepro_core::sql_literal::build_insert_literal(
            "postgres",
            None,
            "binary_exports",
            &columns,
            &[Value::Int(id as i64), value.clone()],
        )
        .unwrap();
        conn.execute(&statement).await.unwrap();
    }
    let result = conn
        .query("SELECT payload FROM binary_exports ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        values.into_iter().map(|value| vec![value]).collect::<Vec<_>>()
    );
}

#[path = "../../../core/tests/support/value_contract.rs"]
mod value_contract;

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_preserves_scalar_boundaries_through_parameters_and_exports() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    value_contract::assert_scalar_contract(connection.as_ref(), "postgres").await;
}
