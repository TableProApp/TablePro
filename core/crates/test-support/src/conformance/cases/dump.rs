use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::dump::{DumpOutput, DumpOutputClosed, DumpRequest, DumpSkipReason, write_dump};
use tablepro_core::import::{SqlImportEnd, SqlImportErrorPolicy, SqlImportOptions, run_sql_import};
use tablepro_core::{Connection, EditorSessionOptions};
use tokio_util::sync::CancellationToken;

use crate::conformance::support::{dial, expect, run_completed, run_options, unexpected, within};
use crate::conformance::{ConformanceFailure, DumpEngine, test_liveness};
use crate::lock;

const CASE: &str = "dump_loads_back_into_an_empty_database";

/// How long a dump of the sample, or its load, may take.
const STEP_LIMIT: Duration = Duration::from_secs(120);

/// The sample goes out as a SQL file, loads through the SQL file import
/// into an empty database as one transaction where the engine has one,
/// and a dump of that database is the same file: the same objects in the
/// same order, the same rows and the same counters.
pub async fn dump_loads_back_into_an_empty_database<E: DumpEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let source = open(&engine, "tp_dump_source").await?;
    let editor = source
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await?;
    for statement in engine.dump_fixture() {
        run_completed(CASE, editor.as_ref(), &statement, run_options()).await?;
    }
    editor.close().await;
    let request = DumpRequest {
        scope: engine.dump_scope(),
        data: true,
    };
    let first = dump(source.as_ref(), &request, &engine.expected_skips()).await?;

    let target = open(&engine, "tp_dump_target").await?;
    let loader = target
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await?;
    let dialect = target.dialect();
    let report = tokio::time::timeout(
        STEP_LIMIT,
        run_sql_import(
            loader.as_ref(),
            &*dialect,
            Box::new(std::io::Cursor::new(first.clone().into_bytes())),
            SqlImportOptions {
                on_error: SqlImportErrorPolicy::Stop,
                one_transaction: true,
            },
            &mut |_| {},
            &CancellationToken::new(),
        ),
    )
    .await
    .map_err(|_| unexpected(CASE, format!("the load did not finish within {STEP_LIMIT:?}")))?;
    loader.close().await;
    expect(
        CASE,
        report.end == SqlImportEnd::Completed && report.failed == 0,
        || format!("the dump did not load back: {:?}\n{first}", report),
    )?;

    let second = dump(target.as_ref(), &request, &[]).await?;
    expect(CASE, first == second, || first_difference(&first, &second))?;
    Ok(())
}

/// The file the engine's own tool wrote loads through the import, run
/// both as one transaction and as written, and holds what it should.
pub async fn native_dump_loads_through_the_import<E: DumpEngine>(engine: E) -> Result<(), ConformanceFailure> {
    const NATIVE: &str = "native_dump_loads_through_the_import";
    let Some(native) = engine.native_dump() else {
        return Ok(());
    };
    for (round, one_transaction) in [true, false].into_iter().enumerate() {
        let target = open(&engine, &format!("tp_native_dump_{round}")).await?;
        let loader = target
            .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
            .await?;
        let dialect = target.dialect();
        let report = tokio::time::timeout(
            STEP_LIMIT,
            run_sql_import(
                loader.as_ref(),
                &*dialect,
                Box::new(std::io::Cursor::new(native.file.as_bytes().to_vec())),
                SqlImportOptions {
                    on_error: SqlImportErrorPolicy::Stop,
                    one_transaction,
                },
                &mut |_| {},
                &CancellationToken::new(),
            ),
        )
        .await
        .map_err(|_| unexpected(NATIVE, "the load did not finish".to_owned()))?;
        expect(
            NATIVE,
            report.end == SqlImportEnd::Completed && report.failed == 0,
            || format!("the native dump did not load (one transaction: {one_transaction}): {report:?}"),
        )?;
        for (sql, expected) in &native.checks {
            let collected = run_completed(NATIVE, loader.as_ref(), sql, run_options()).await?;
            let found = collected
                .rows()
                .first()
                .and_then(|row| row.first())
                .and_then(tablepro_core::export::value_to_text);
            expect(NATIVE, found.as_deref() == Some(expected.as_str()), || {
                format!("`{sql}` gave {found:?}, not {expected}")
            })?;
        }
        loader.close().await;
    }
    Ok(())
}

async fn open<E: DumpEngine>(engine: &E, name: &str) -> Result<Arc<dyn Connection>, ConformanceFailure> {
    let mut options = engine.empty_database(name).await?;
    options.liveness = test_liveness();
    Ok(dial(CASE, E::driver(), options).await??)
}

async fn dump(
    connection: &dyn Connection,
    request: &DumpRequest,
    expected_skips: &[(String, DumpSkipReason)],
) -> Result<String, ConformanceFailure> {
    let mut output = Collected::default();
    let report = tokio::time::timeout(
        STEP_LIMIT,
        write_dump(connection, request, &mut output, within(STEP_LIMIT)),
    )
    .await
    .map_err(|_| unexpected(CASE, format!("the dump did not finish within {STEP_LIMIT:?}")))?
    .map_err(|error| unexpected(CASE, format!("the dump failed: {error}")))?;
    let text = String::from_utf8(lock(&output.bytes).clone())
        .map_err(|_| unexpected(CASE, "the dump is not UTF-8".to_owned()))?;
    let skipped: Vec<(String, DumpSkipReason)> = report
        .skipped
        .iter()
        .map(|skip| (skip.name.clone(), skip.reason))
        .collect();
    expect(CASE, report.omitted.is_empty() && skipped == expected_skips, || {
        format!(
            "the dump left values or objects out: {:?} {:?}\n{text}",
            report.omitted, report.skipped
        )
    })?;
    expect(CASE, report.rows > 0 && report.tables > 0, || {
        format!("the dump wrote no rows: {report:?}\n{text}")
    })?;
    Ok(text)
}

fn first_difference(first: &str, second: &str) -> String {
    let (left, right): (Vec<&str>, Vec<&str>) = (first.lines().collect(), second.lines().collect());
    let at = left
        .iter()
        .zip(&right)
        .position(|(a, b)| a != b)
        .unwrap_or(left.len().min(right.len()));
    let around = |lines: &[&str]| {
        lines
            .get(at.saturating_sub(3)..(at + 4).min(lines.len()))
            .unwrap_or_default()
            .join("\n")
    };
    format!(
        "the reloaded database dumps differently from line {}:\n--- source\n{}\n--- reloaded\n{}\n=== whole source dump\n{first}",
        at + 1,
        around(&left),
        around(&right)
    )
}

#[derive(Default)]
struct Collected {
    bytes: Arc<Mutex<Vec<u8>>>,
}

#[async_trait]
impl DumpOutput for Collected {
    async fn write(&mut self, bytes: Vec<u8>) -> Result<(), DumpOutputClosed> {
        lock(&self.bytes).extend_from_slice(&bytes);
        Ok(())
    }
}
