// DuckDB parses, binds, reads and prints an expression one call per level, partly on threads of its own, and a
// level past what a thread's stack holds ends the process. A target of its own, which CI also runs on Windows and
// macOS, where those threads get other stacks than on Linux.

// cfg(test) is what lets the helpers fail a case with unwrap.
#[cfg(test)]
mod cases {
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use std::time::Duration;

    use tablepro_core::meta::{ObjectScope, TableRef};
    use tablepro_core::statement::{GuardedStatement, Statement, StatementBuilder};
    use tablepro_core::{
        CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, Connection, DatabaseDriver, DriverError,
        EditorSessionOptions, FileEndpoint, ForeignKeyMode, RowLimit, RunEnd, RunOptions, ServerCode, SinkFlow,
        UserSql, WorkspaceSettings, WriteBatch, WriteKind,
    };
    use tablepro_driver_duckdb::DuckDbDriver;
    use tablepro_test_support::conformance::test_liveness;
    use tempfile::TempDir;
    use tokio::time::Instant;
    use tokio_util::sync::CancellationToken;

    // The deepest a CHECK, DEFAULT, generated column, view or macro nests under DuckDB's own default limit of 1,000.
    const DUCKDB_DEFAULT_DEPTH: usize = 992;

    fn nested(levels: usize, inner: &str) -> String {
        format!("{}{inner}{}", "abs(".repeat(levels), ")".repeat(levels))
    }

    // DuckDB recurses while it writes these too, so the file is made on a stack that holds them, on that one thread:
    // a CHECKPOINT statement runs on DuckDB's own threads otherwise.
    fn create(directory: &TempDir, statements: Vec<String>) -> PathBuf {
        let path = directory.path().join("deep.duckdb");
        let target = path.clone();
        std::thread::Builder::new()
            .stack_size(256 << 20)
            .spawn(move || {
                let writer = duckdb::Connection::open_with_flags(&target, duckdb::Config::default().threads(1)?)?;
                statements.iter().try_for_each(|sql| writer.execute_batch(sql))
            })
            .unwrap()
            .join()
            .unwrap()
            .unwrap();
        path
    }

    async fn open(path: &Path) -> Arc<dyn Connection> {
        let options = ConnectOptions {
            target: ConnectTarget::File(FileEndpoint::open_existing(path.to_path_buf()).unwrap()),
            workspace_settings: WorkspaceSettings::workspace(false),
            liveness: test_liveness(),
            environment: ConnectEnvironment::new("test"),
        };
        DuckDbDriver.connect(options, CancellationToken::new()).await.unwrap()
    }

    fn call() -> CallOptions {
        CallOptions::new(Some(Instant::now() + Duration::from_secs(60)), CancellationToken::new())
    }

    fn statement(sql: &str) -> Statement {
        let mut builder = StatementBuilder::new();
        builder.push_sql(sql);
        builder.finish()
    }

    async fn query(connection: &dyn Connection, sql: &str) -> Result<tablepro_core::QueryResult, DriverError> {
        connection
            .query_bound(&statement(sql), RowLimit::EDITOR_DEFAULT, call())
            .await
    }

    struct Discard;

    #[async_trait::async_trait]
    impl tablepro_core::ResultSink for Discard {
        async fn accept(&mut self, _event: tablepro_core::ResultEvent) -> SinkFlow {
            SinkFlow::Continue
        }
    }

    #[track_caller]
    fn refused_as_too_deep<T: std::fmt::Debug>(read: &str, result: Result<T, DriverError>) {
        let error = match result {
            Err(DriverError::RolledBack { source, .. }) => *source,
            Err(error) => error,
            Ok(value) => panic!("{read} read a value: {value:?}"),
        };
        let DriverError::Server(diagnostics) = &error else {
            panic!("{read}: {error:?}");
        };
        assert!(
            matches!(&diagnostics.code, Some(ServerCode::DuckDb { error_type }) if error_type == "Binder" || error_type == "Parser"),
            "{read}: {error:?}"
        );
        assert!(
            diagnostics
                .message
                .starts_with("Max expression depth limit of 250 exceeded"),
            "{read}: {error:?}"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_file_as_deep_as_duckdb_allows_is_read_or_refused() {
        let directory = tempfile::tempdir().unwrap();
        let path = create(
            &directory,
            vec![format!(
                "CREATE TABLE other (id INTEGER PRIMARY KEY); \
                 CREATE TABLE t (a INTEGER CHECK ({check} > 0), b INTEGER DEFAULT ({default}), c INTEGER AS ({check})); \
                 CREATE VIEW v AS SELECT {check} AS x FROM t; \
                 CREATE MACRO m(x) AS {macro_body}; \
                 CHECKPOINT;",
                check = nested(DUCKDB_DEFAULT_DEPTH, "a"),
                default = nested(DUCKDB_DEFAULT_DEPTH, "1"),
                macro_body = nested(DUCKDB_DEFAULT_DEPTH, "x"),
            )],
        );
        let connection = open(&path).await;
        let table = |name: &str| TableRef::new(Some("main".to_owned()), name);

        let objects = connection
            .list_objects(&ObjectScope::DefaultSchema, call())
            .await
            .unwrap();
        assert_eq!(
            objects.iter().map(|object| object.name.as_str()).collect::<Vec<_>>(),
            ["other", "t", "v"]
        );
        refused_as_too_deep("the columns of t", connection.fetch_columns(&table("t"), call()).await);
        refused_as_too_deep(
            "the definition of other",
            connection.fetch_table_definition(&table("other"), call()).await,
        );
        refused_as_too_deep(
            "the keys of other",
            connection.fetch_foreign_keys(&table("other"), call()).await,
        );
        refused_as_too_deep("the view", query(connection.as_ref(), "SELECT * FROM v").await);
        refused_as_too_deep("the macro", query(connection.as_ref(), "SELECT m(1)").await);
        let insert = WriteBatch::new(
            WriteKind::SchemaChanges,
            TableRef::unqualified("t"),
            vec![GuardedStatement::unguarded(statement("INSERT INTO t (a) VALUES (1)"))],
            ForeignKeyMode::Enforced,
        );
        refused_as_too_deep("an insert", connection.write_batch(&insert, call()).await);
        connection.close().await.unwrap();
    }

    // Made by raising DuckDB's limit. DuckDB reads it back at open with no limit of its own, deeper than the 2 MiB a
    // runtime's blocking thread has.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_file_deeper_than_a_runtime_thread_holds_opens() {
        let directory = tempfile::tempdir().unwrap();
        let path = create(
            &directory,
            vec![
                "SET max_expression_depth = 100000".to_owned(),
                format!(
                    "CREATE TABLE t (a INTEGER CHECK ({} > 0)); CHECKPOINT;",
                    nested(3_000, "a")
                ),
            ],
        );

        let connection = open(&path).await;

        assert_eq!(connection.server_info().product, "DuckDB");
        connection.close().await.unwrap();
    }

    // A tab's SET GLOBAL reaches every connection to the database; the app's own reads keep the limit.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn the_limit_holds_on_every_connection_after_a_tab_raises_it() {
        let directory = tempfile::tempdir().unwrap();
        let path = create(&directory, vec!["CHECKPOINT".to_owned()]);
        let connection = open(&path).await;
        let editor = connection
            .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
            .await
            .unwrap();
        let run = |sql: &str| {
            let sql = UserSql::new(sql);
            let editor = editor.clone();
            async move {
                editor
                    .run(sql, RunOptions::new(CancellationToken::new()), Box::new(Discard))
                    .await
                    .unwrap()
                    .end
            }
        };
        let select = |levels: usize| format!("SELECT {}", nested(levels, "1"));

        assert_eq!(run(&select(240)).await, RunEnd::Completed);
        let RunEnd::Failed(refused) = run(&select(250)).await else {
            panic!("the tab ran an expression past the limit");
        };
        refused_as_too_deep("the tab", Err::<(), _>(refused));

        assert_eq!(run("SET GLOBAL max_expression_depth = 100000").await, RunEnd::Completed);
        assert!(query(connection.as_ref(), &select(240)).await.is_ok());
        refused_as_too_deep("the workspace", query(connection.as_ref(), &select(250)).await);
        editor.close().await;
        connection.close().await.unwrap();
    }
}
