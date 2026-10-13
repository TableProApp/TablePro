//! The catalogue as the sidebar, the grid and the structure tab read it.

use tablepro_core::column::ColumnDefault;
use tablepro_core::column::{
    BoolStorage, ColumnKind, FloatWidth, IntegerKind, IntegerWidth, NetworkFamily, ReadForm, TemporalZone, TextLength,
};
use tablepro_core::ddl::{CollationName, GeneratedStorage, IdentityStyle};
use tablepro_core::meta::{EngineRowId, IndexKey, ObjectKind, ObjectScope, RowCountEstimate, RowIdentity, TableRef};
use tablepro_core::save::{ChangeSet, RowChange, RowUpdate, plan_save};
use tablepro_core::{DriverError, Value};
use tablepro_test_fixtures::{HbaMode, PostgresFixture, PostgresVersion};

use crate::support::{CALL, connect, rows, run_ok, scalar, session, setup, start, text, within};

fn table(name: &str) -> TableRef {
    TableRef::new(Some("public".to_owned()), name)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn object_kinds_listed() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE plain (id int)",
            "CREATE TABLE parted (id int) PARTITION BY RANGE (id)",
            "CREATE TABLE parted_low PARTITION OF parted FOR VALUES FROM (0) TO (10)",
            "CREATE VIEW seen AS SELECT 1 AS n",
            "CREATE MATERIALIZED VIEW kept AS SELECT 1 AS n",
            "CREATE SEQUENCE counter",
            "CREATE FUNCTION f() RETURNS int LANGUAGE sql AS 'SELECT 1'",
            "CREATE PROCEDURE p() LANGUAGE sql AS 'SELECT 1'",
        ],
    )
    .await;

    let objects = connection
        .list_objects(&ObjectScope::DefaultSchema, within(CALL))
        .await
        .expect("the objects");

    let kind_of = |name: &str| {
        objects
            .iter()
            .find(|object| object.name == name)
            .map(|object| object.kind)
    };
    assert_eq!(kind_of("plain"), Some(ObjectKind::Table));
    assert_eq!(kind_of("parted"), Some(ObjectKind::PartitionedTable));
    assert_eq!(kind_of("parted_low"), Some(ObjectKind::Table));
    assert_eq!(kind_of("seen"), Some(ObjectKind::View));
    assert_eq!(kind_of("kept"), Some(ObjectKind::MaterializedView));
    assert_eq!(kind_of("counter"), Some(ObjectKind::Sequence));
    assert_eq!(kind_of("f"), Some(ObjectKind::Function));
    assert_eq!(kind_of("p"), Some(ObjectKind::Procedure));
    assert!(objects.iter().all(|object| object.schema.as_deref() == Some("public")));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn other_session_temp_table_excluded() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let other = session(connection.as_ref()).await;
    run_ok(other.as_ref(), "CREATE TEMP TABLE private_scratch (n int)").await;

    let schemas = connection.list_schemas(within(CALL)).await.expect("the schemas");
    let objects = connection
        .list_objects(&ObjectScope::AllSchemas, within(CALL))
        .await
        .expect("the objects");

    assert!(
        !schemas.iter().any(|schema| schema.name.starts_with("pg_temp")),
        "{schemas:?}"
    );
    assert!(!objects.iter().any(|object| object.name == "private_scratch"));
    assert!(
        schemas
            .iter()
            .any(|schema| schema.name == "public" && schema.is_default)
    );
    assert!(
        schemas
            .iter()
            .any(|schema| schema.name == "pg_catalog" && schema.is_system)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn expression_desc_partial_index_keys() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE t (id int PRIMARY KEY, label text)",
            "CREATE UNIQUE INDEX t_label ON t (lower(label) DESC, id) WHERE id > 0",
        ],
    )
    .await;

    let indexes = connection
        .fetch_indexes(&table("t"), within(CALL))
        .await
        .expect("the indexes");

    let partial = indexes
        .iter()
        .find(|index| index.name == "t_label")
        .expect("the partial index");
    assert!(partial.unique && !partial.primary);
    assert_eq!(partial.predicate.as_deref(), Some("(id > 0)"));
    assert_eq!(
        partial.keys,
        vec![
            IndexKey::Expression {
                sql: "lower(label)".to_owned(),
                descending: true
            },
            IndexKey::Column {
                name: "id".to_owned(),
                descending: false
            },
        ]
    );
    assert!(!partial.can_identify_rows());
    assert!(
        indexes
            .iter()
            .any(|index| index.primary && index.key_columns() == ["id"])
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn identity_pk_unique_notnull_ctid_partitioned() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE keyed (id int PRIMARY KEY)",
            "CREATE TABLE coded (code text NOT NULL UNIQUE, other int)",
            "CREATE TABLE nullable_unique (code text UNIQUE)",
            "CREATE TABLE bare (n int)",
            "CREATE TABLE parted (n int) PARTITION BY RANGE (n)",
            "CREATE VIEW seen AS SELECT 1 AS n",
        ],
    )
    .await;
    let identity = |name: &'static str| {
        let connection = connection.clone();
        async move { connection.row_identity(&table(name), within(CALL)).await }
    };

    assert_eq!(
        identity("keyed").await,
        Ok(RowIdentity::UniqueKey {
            columns: vec!["id".to_owned()]
        })
    );
    assert_eq!(
        identity("coded").await,
        Ok(RowIdentity::UniqueKey {
            columns: vec!["code".to_owned()]
        })
    );
    assert_eq!(
        identity("nullable_unique").await,
        Ok(RowIdentity::EngineRowId(EngineRowId::PostgresCtid))
    );
    assert_eq!(
        identity("bare").await,
        Ok(RowIdentity::EngineRowId(EngineRowId::PostgresCtid))
    );
    assert_eq!(
        identity("parted").await,
        Ok(RowIdentity::EngineRowId(EngineRowId::PostgresTableoidCtid))
    );
    assert_eq!(identity("seen").await, Ok(RowIdentity::Unordered));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn stale_ctid_edit_after_vacuum_reuse_row_guard_failed() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE t (v text)", "INSERT INTO t VALUES ('old')"],
    )
    .await;
    let target = table("t");
    let before = rows(connection.as_ref(), "SELECT ctid::text, xmin::text FROM t").await;
    let maintenance = session(connection.as_ref()).await;
    run_ok(maintenance.as_ref(), "DELETE FROM t").await;
    run_ok(maintenance.as_ref(), "VACUUM t").await;
    run_ok(maintenance.as_ref(), "INSERT INTO t VALUES ('new')").await;
    let after = rows(connection.as_ref(), "SELECT ctid::text FROM t").await;
    let columns = connection
        .fetch_columns(&target, within(CALL))
        .await
        .expect("the columns");
    let identity = connection
        .row_identity(&target, within(CALL))
        .await
        .expect("the identity");
    let dialect = connection.dialect();
    let changes = ChangeSet {
        changes: vec![RowChange::Update(RowUpdate {
            key: before[0].clone(),
            assignments: vec![(0, Value::Text("changed".to_owned()))],
        })],
    };
    let plan = plan_save(dialect.as_ref(), &target, &columns, &identity, &changes).expect("a plan");

    let outcome = connection.write_batch(&plan.batch, within(CALL)).await;

    assert_eq!(after[0][0], before[0][0], "VACUUM did not hand the slot to the new row");
    assert_eq!(identity, RowIdentity::EngineRowId(EngineRowId::PostgresCtid));
    assert!(
        matches!(outcome, Err(DriverError::RowGuardFailed { actual: 0, .. })),
        "{outcome:?}"
    );
    assert_eq!(text(&scalar(connection.as_ref(), "SELECT v FROM t").await), "new");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn estimate_heap_blocks_matches_relation_size() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE t AS SELECT generate_series(1, 1000) AS n"],
    )
    .await;
    let maintenance = session(connection.as_ref()).await;
    run_ok(maintenance.as_ref(), "ANALYZE t").await;

    let estimate = connection
        .table_estimate(&table("t"), within(CALL))
        .await
        .expect("an estimate");
    let blocks = scalar(
        connection.as_ref(),
        "SELECT pg_relation_size('t') / current_setting('block_size')::int8",
    )
    .await;

    assert_eq!(estimate.rows, RowCountEstimate::Approximate(1000));
    assert_eq!(
        estimate.heap_blocks.map(|blocks| Value::Int(blocks as i64)),
        Some(blocks)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn fetch_table_definition_reports_pk_name_collation_comment_and_inbound_keys() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE parent (id int CONSTRAINT parent_key PRIMARY KEY, name text COLLATE \"C\", \
             doubled int GENERATED ALWAYS AS (id * 2) STORED, serial_no serial, ident int GENERATED BY DEFAULT AS IDENTITY)",
            "COMMENT ON COLUMN parent.name IS 'the name'",
            "CREATE TABLE child (parent_id int REFERENCES parent (id) ON DELETE CASCADE)",
        ],
    )
    .await;

    let definition = connection
        .fetch_table_definition(&table("parent"), within(CALL))
        .await
        .expect("the definition");

    let primary_key = definition.primary_key.clone().expect("a primary key");
    assert_eq!(primary_key.name.as_deref(), Some("parent_key"));
    assert_eq!(primary_key.columns, ["id"]);
    let name = definition.column("name").expect("the name column");
    assert_eq!(
        name.attributes.collation,
        Some(CollationName::new(Some("pg_catalog".to_owned()), "C"))
    );
    assert_eq!(name.info.comment.as_deref(), Some("the name"));
    let doubled = definition.column("doubled").expect("the generated column");
    assert!(doubled.info.is_generated);
    assert_eq!(
        doubled.attributes.generated.as_ref().map(|generated| generated.storage),
        Some(GeneratedStorage::Stored)
    );
    assert_eq!(
        definition.column("serial_no").map(|column| column.attributes.identity),
        Some(IdentityStyle::SequenceDefault)
    );
    assert_eq!(
        definition.column("ident").map(|column| column.attributes.identity),
        Some(IdentityStyle::GeneratedByDefault)
    );
    assert_eq!(definition.inbound_foreign_keys.len(), 1);
    let inbound = &definition.inbound_foreign_keys[0];
    assert_eq!(inbound.table, table("child"));
    assert_eq!(inbound.columns, ["parent_id"]);
    assert_eq!(inbound.referenced_columns, ["id"]);
    let outbound = connection
        .fetch_foreign_keys(&table("child"), within(CALL))
        .await
        .expect("the foreign keys");
    assert_eq!(outbound.len(), 1);
    assert_eq!(outbound[0].ref_table, "parent");
    assert_eq!(
        outbound[0].on_delete,
        Some(tablepro_core::ddl::ReferentialAction::Cascade)
    );
    assert!(definition.source.is_none());
}

const CATALOG_TABLE: &[&str] = &[
    "CREATE TYPE mood AS ENUM ('sad', 'ok', 'happy')",
    "CREATE DOMAIN positive AS int4 CHECK (VALUE > 0)",
    "CREATE TABLE typed (
        id serial PRIMARY KEY,
        small int2 NOT NULL DEFAULT 7,
        num numeric(10, 2),
        price money,
        name varchar(20) DEFAULT 'it''s',
        code char(4),
        flag boolean,
        born date,
        at timestamptz(3) DEFAULT now(),
        t time(3),
        tz timetz,
        span interval,
        bits bit(8),
        vbits varbit(16),
        doc jsonb,
        u uuid,
        addr inet,
        mac macaddr,
        tags text[],
        feeling mood,
        pos point,
        r int4range,
        tsv tsvector,
        count positive,
        ratio float4
    )",
];

async fn catalog_matches_information_schema(version: PostgresVersion) {
    let fixture = PostgresFixture::start_version(version, HbaMode::Password)
        .await
        .expect("a PostgreSQL container");
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), CATALOG_TABLE).await;

    let columns = connection
        .fetch_columns(&table("typed"), within(CALL))
        .await
        .expect("the columns");
    let schema = rows(
        connection.as_ref(),
        "SELECT column_name::text, (is_nullable = 'YES') FROM information_schema.columns \
         WHERE table_name = 'typed' ORDER BY ordinal_position",
    )
    .await;

    let ours: Vec<(String, Value)> = columns
        .iter()
        .map(|column| (column.name.clone(), Value::Bool(column.nullable)))
        .collect();
    let theirs: Vec<(String, Value)> = schema.iter().map(|row| (text(&row[0]), row[1].clone())).collect();
    assert_eq!(ours, theirs, "PostgreSQL {}", version.major());

    let column = |name: &str| columns.iter().find(|column| column.name == name).expect("a column");
    let int = |width| ColumnKind::Integer(IntegerKind { width, signed: true });
    let cases: Vec<(&str, ColumnKind, ReadForm)> = vec![
        ("id", int(IntegerWidth::W32), ReadForm::Native),
        ("small", int(IntegerWidth::W16), ReadForm::Native),
        (
            "num",
            ColumnKind::Decimal {
                precision: Some(10),
                scale: Some(2),
            },
            ReadForm::Native,
        ),
        ("price", ColumnKind::Money { scale: None }, ReadForm::ServerNumeric),
        (
            "name",
            ColumnKind::Text {
                length: TextLength::Varying(20),
            },
            ReadForm::Native,
        ),
        (
            "code",
            ColumnKind::Text {
                length: TextLength::Fixed(4),
            },
            ReadForm::Native,
        ),
        ("flag", ColumnKind::Bool(BoolStorage::Native), ReadForm::Native),
        ("born", ColumnKind::Date, ReadForm::Native),
        (
            "at",
            ColumnKind::Timestamp {
                fractional_digits: Some(3),
                zone: TemporalZone::Offset,
            },
            ReadForm::Native,
        ),
        (
            "bits",
            ColumnKind::BitString {
                length: Some(8),
                varying: false,
            },
            ReadForm::Native,
        ),
        ("doc", ColumnKind::Json { binary: true }, ReadForm::Native),
        ("addr", ColumnKind::Network(NetworkFamily::Inet), ReadForm::Native),
        (
            "tags",
            ColumnKind::Array {
                element: Box::new(ColumnKind::Text {
                    length: TextLength::Unbounded,
                }),
            },
            ReadForm::Native,
        ),
        (
            "feeling",
            ColumnKind::Enum {
                labels: vec!["sad".to_owned(), "ok".to_owned(), "happy".to_owned()],
                multiple: false,
            },
            ReadForm::ServerText,
        ),
        ("pos", ColumnKind::Spatial, ReadForm::Native),
        ("r", ColumnKind::Other, ReadForm::ServerText),
        ("tsv", ColumnKind::Other, ReadForm::ServerText),
        ("count", int(IntegerWidth::W32), ReadForm::Native),
        ("ratio", ColumnKind::Float(FloatWidth::F32), ReadForm::Native),
    ];
    for (name, kind, read_form) in cases {
        let info = column(name);
        assert_eq!(info.column_type.kind, kind, "{name} on PostgreSQL {}", version.major());
        assert_eq!(
            info.column_type.read_form,
            read_form,
            "{name} on PostgreSQL {}",
            version.major()
        );
    }
    assert!(column("id").primary_key && column("id").is_auto_increment);
    assert_eq!(column("id").default, ColumnDefault::None);
    assert_eq!(column("small").default, ColumnDefault::Literal(Value::Int(7)));
    assert_eq!(
        column("name").default,
        ColumnDefault::Literal(Value::Text("it's".to_owned()))
    );
    assert!(column("at").default.needs_server_evaluation());
    assert_eq!(
        column("count")
            .column_type
            .catalog
            .as_ref()
            .map(|catalog| catalog.cast_target.as_sql().to_owned()),
        Some("positive".to_owned())
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn catalog_matches_information_schema_on_13() {
    catalog_matches_information_schema(PostgresVersion::V13).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn catalog_matches_information_schema_on_18() {
    catalog_matches_information_schema(PostgresVersion::V18).await;
}

/// No statement is cached under a name, so a column added after the pool
/// warmed up shows on every pooled connection at once.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn alter_add_column_then_query_bound_on_all_four_pooled_connections() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE t (id int)", "INSERT INTO t VALUES (1)"],
    )
    .await;
    let warm = (0..drivers_postgres::WORKSPACE_POOL_MAX_SIZE).map(|_| {
        let connection = connection.clone();
        async move {
            connection
                .query_bound(
                    &crate::support::statement("SELECT *, pg_sleep(0.2) FROM t"),
                    tablepro_core::RowLimit::EDITOR_DEFAULT,
                    within(CALL),
                )
                .await
        }
    });
    for warmed in futures_util::future::join_all(warm).await {
        warmed.expect("a warm-up read");
    }
    setup(
        connection.as_ref(),
        &["ALTER TABLE t ADD COLUMN extra text DEFAULT 'x'"],
    )
    .await;

    let reads = (0..drivers_postgres::WORKSPACE_POOL_MAX_SIZE).map(|_| {
        let connection = connection.clone();
        async move {
            connection
                .query_bound(
                    &crate::support::statement("SELECT *, pg_sleep(0.2) FROM t"),
                    tablepro_core::RowLimit::EDITOR_DEFAULT,
                    within(CALL),
                )
                .await
        }
    });
    for read in futures_util::future::join_all(reads).await {
        let read = read.expect("a read after the change");
        assert_eq!(read.columns.len(), 3, "{:?}", read.columns);
        assert_eq!(read.rows[0][1], Value::Text("x".to_owned()));
    }
}
