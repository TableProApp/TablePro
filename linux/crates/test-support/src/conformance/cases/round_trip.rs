use std::collections::{BTreeMap, BTreeSet};
use std::hash::{DefaultHasher, Hash, Hasher};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::browse::{DeclaredPrecisionSink, ExportRequest, build_export};
use tablepro_core::column::{ColumnInfo, ColumnType, ResultColumn};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::edit::{EditText, edit_text, read_only_reason};
use tablepro_core::export::{
    CellsEncoder, CsvDelimiter, CsvEncoder, CsvLineBreak, CsvOptions, CsvQuote, RowEncoder, SqlInsertEncoder,
    TsvEncoder,
};
use tablepro_core::import::{CsvImportOptions, MAX_CSV_FILE_BYTES, PastedTable};
use tablepro_core::meta::RowIdentity;
use tablepro_core::save::{ChangeSet, RowChange, plan_save};
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan};
use tablepro_core::{
    Connection, EditorSession, EditorSessionOptions, FilterSet, ReadStatement, ResultEvent, ResultSink, SinkFlow,
    TableRef, Value, WriteKind,
};
use tokio_util::sync::CancellationToken;

use crate::conformance::cases::value_corpus::{corpus_table, load, quoted, shown};
use crate::conformance::support::{
    CALL_DEADLINE, apply_within, connect, create_scratch_table, expect, run_editor, run_options, unexpected, within,
    writable,
};
use crate::conformance::{ConformanceFailure, LargeTableEngine, ValueCorpusEngine};
use crate::{import_csv, lock};

const CSV_CASE: &str = "csv_export_imports_back_as_the_same_rows";
const SQL_CASE: &str = "sql_insert_export_runs_back_as_the_same_rows";
const NEAR_LIMIT_CASE: &str = "csv_export_near_the_import_limit_imports_back";
const PASTE_CASE: &str = "tsv_copy_pastes_back_as_the_same_rows";

/// What the import reads as NULL in every pairing, and what the export
/// writes for one.
const NULL_MARKER: &str = "NULL";

/// The app gives an import the row save's 120 seconds, and five more for
/// each statement.
const IMPORT_DEADLINE: Duration = Duration::from_secs(120);

/// An export has no deadline in the app. This one only stops a read
/// that hangs.
const EXPORT_DEADLINE: Duration = Duration::from_secs(120);

/// Under the export defaults these rows of 200-character labels make a
/// file just under `MAX_CSV_FILE_BYTES`. 200 characters is the widest
/// label every engine's scratch table takes.
const NEAR_LIMIT_ROWS: u64 = 315_000;
const NEAR_LIMIT_LABEL_WIDTH: usize = 200;

/// How far under the limit the file may land and still test it.
const NEAR_LIMIT_MARGIN: usize = 1024 * 1024;

const FILL_DEADLINE: Duration = Duration::from_secs(120);

/// The app adds five seconds a statement to the row save's 120, which
/// for a file this size runs past the case's own limit.
const NEAR_LIMIT_IMPORT_DEADLINE: Duration = Duration::from_secs(180);

/// A case makes a table and its copies for every corpus column, or
/// fills, exports and imports a 64 MiB table, so it takes longer than
/// `CASE_LIMIT`, and still ends before the `ci` nextest profile kills the
/// test at five minutes.
pub const ROUND_TRIP_CASE_LIMIT: Duration = Duration::from_secs(240);

/// Rows of `id` whose differences are listed when a large table does
/// not come back whole.
const LISTED_IDS: usize = 10;

/// Every corpus value with a text form exports as CSV and imports into
/// an empty copy of its table with the same rows, under each pairing of
/// writer and reader options that is meant to be lossless. A column of
/// a kind the import refuses, such as a blob or an array, and a value
/// with no text form, such as a blob in a SQLite column typed by its
/// values, are the SQL case's: CSV has no text that reads back as them.
pub async fn csv_export_imports_back_as_the_same_rows<E: ValueCorpusEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let corpus = engine.value_corpus();
    expect(CSV_CASE, !corpus.is_empty(), || "the engine lists no corpus".to_owned())?;
    let connection = connect(CSV_CASE, &engine, writable()).await?;
    let mut wrong = Vec::new();
    let mut round_trips = 0;
    for (index, column) in corpus.iter().enumerate() {
        let source = match load(&engine, connection.as_ref(), &format!("csv_{index}"), column).await {
            Ok(table) => table,
            Err(failure) => {
                wrong.push(failure.to_string());
                continue;
            }
        };
        let columns = connection.fetch_columns(&source, within(CALL_DEADLINE)).await?;
        if columns
            .iter()
            .any(|info| read_only_reason(&info.column_type.kind).is_some())
        {
            continue;
        }
        let expected = read_rows(connection.as_ref(), &source, texts, KeepValues::Yes).await?;
        for (writer, reader) in pairings() {
            let what = format!(
                "`{}` as {:?}, {:?}, {:?}",
                column.declaration, writer.delimiter, writer.quote, writer.line_break
            );
            let copy = corpus_table(&engine, connection.as_ref(), &format!("csv_{index}_copy"), column, &[]).await?;
            let file = encode(&expected.values, &csv_encoder(writer))?;
            if let Err(failure) = import_csv(connection.as_ref(), &copy, &file, &reader, within(IMPORT_DEADLINE)).await
            {
                wrong.push(format!("{what}: the import failed: {failure:?}"));
                continue;
            }
            let actual = read_rows(connection.as_ref(), &copy, texts, KeepValues::No).await?;
            wrong.extend(differences(&what, &expected, &actual, &expected.without_text));
            round_trips += 1;
        }
    }
    connection.close().await?;
    expect(CSV_CASE, round_trips > 0, || {
        "no corpus column could travel as CSV".to_owned()
    })?;
    expect(CSV_CASE, wrong.is_empty(), || {
        format!(
            "{} differences after a CSV round trip:\n{}",
            wrong.len(),
            wrong.join("\n")
        )
    })
}

/// Every corpus value with a text form, copied from the grid as rows and
/// pasted into an empty copy of its table, saves as the same rows. A
/// copy offers the cells and their text: each is pasted on its own, read
/// as a paste reads it, and saved as a table tab saves new rows.
///
/// The rows are compared in the order of their `id`, without it: a
/// paste leaves an id the server numbers, such as SQLite's row id, to
/// the server.
pub async fn tsv_copy_pastes_back_as_the_same_rows<E: ValueCorpusEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let corpus = engine.value_corpus();
    expect(PASTE_CASE, !corpus.is_empty(), || {
        "the engine lists no corpus".to_owned()
    })?;
    let connection = connect(PASTE_CASE, &engine, writable()).await?;
    let mut wrong = Vec::new();
    let mut round_trips = 0;
    for (index, column) in corpus.iter().enumerate() {
        let source = match load(&engine, connection.as_ref(), &format!("tsv_{index}"), column).await {
            Ok(table) => table,
            Err(failure) => {
                wrong.push(failure.to_string());
                continue;
            }
        };
        let columns = connection.fetch_columns(&source, within(CALL_DEADLINE)).await?;
        if columns
            .iter()
            .any(|info| read_only_reason(&info.column_type.kind).is_some())
        {
            continue;
        }
        let mut expected = read_rows(connection.as_ref(), &source, texts, KeepValues::Yes).await?;
        let read_columns = expected.values.columns.clone();
        expected
            .values
            .rows
            .retain(|row| has_text(read_columns.as_deref(), row));
        let typed = read_rows(connection.as_ref(), &source, typed_texts, KeepValues::No).await?;
        let text = String::from_utf8(encode(&expected.values, &tsv_encoder())?).map_err(ConformanceFailure::setup)?;
        let cells = encode(&expected.values, &cells_encoder())?;
        // Text carries no kinds, as a column SQLite types by its values
        // shows; the cells keep how each value was stored.
        let pastes = [
            ("text", PastedTable::read(&text), texts as Keep, &expected),
            ("cells", PastedTable::from_cells(&cells), typed_texts as Keep, &typed),
        ];
        for (copy_index, (form, pasted, keep, source_rows)) in pastes.into_iter().enumerate() {
            let what = format!("`{}` copied and pasted as {form}", column.declaration);
            let copy = corpus_table(
                &engine,
                connection.as_ref(),
                &format!("tsv_{index}_copy_{copy_index}"),
                column,
                &[],
            )
            .await?;
            let pasted = match pasted {
                Ok(pasted) => pasted,
                Err(error) => {
                    wrong.push(format!("{what}: the copy did not read as rows: {error}"));
                    continue;
                }
            };
            if let Some(failure) = paste(connection.as_ref(), &copy, &pasted).await? {
                wrong.push(format!("{what}: {failure}"));
                continue;
            }
            let actual = read_rows(connection.as_ref(), &copy, keep, KeepValues::No).await?;
            wrong.extend(order_differences(
                &what,
                &in_id_order(source_rows, &source_rows.without_text),
                &in_id_order(&actual, &BTreeSet::new()),
            ));
            round_trips += 1;
        }
    }
    connection.close().await?;
    expect(PASTE_CASE, round_trips > 0, || {
        "no corpus column could travel as copied rows".to_owned()
    })?;
    expect(PASTE_CASE, wrong.is_empty(), || {
        format!(
            "{} differences after a copy and paste:\n{}",
            wrong.len(),
            wrong.join("\n")
        )
    })
}

/// Paste `pasted` into `table` and save the rows, as a table tab does
/// with the rows a paste gives it. Returns why that stopped short.
async fn paste(
    connection: &dyn Connection,
    table: &TableRef,
    pasted: &PastedTable,
) -> Result<Option<String>, ConformanceFailure> {
    let columns = connection.fetch_columns(table, within(CALL_DEADLINE)).await?;
    let in_order: Vec<usize> = (0..columns.len()).collect();
    let rows = match pasted.rows(&columns, &in_order) {
        Ok(rows) => rows,
        Err(error) => return Ok(Some(format!("the paste refused a value: {error:?}"))),
    };
    let identity = RowIdentity::UniqueKey {
        columns: columns
            .iter()
            .filter(|column| column.primary_key)
            .map(|column| column.name.clone())
            .collect(),
    };
    let changes = ChangeSet {
        changes: rows.rows.into_iter().map(|cells| RowChange::Insert { cells }).collect(),
    };
    let plan = match plan_save(&*connection.dialect(), table, &columns, &identity, &changes) {
        Ok(plan) => plan,
        Err(error) => return Ok(Some(format!("the save could not be planned: {error}"))),
    };
    Ok(connection
        .write_batch(&plan.batch, within(IMPORT_DEADLINE))
        .await
        .err()
        .map(|error| format!("the save failed: {error}")))
}

/// Rows as the grid's Copy writes them: tab-separated, no header.
fn tsv_encoder() -> EncoderFor {
    Box::new(|columns| Box::new(TsvEncoder::new(columns, false)))
}

/// The cells the grid's Copy offers beside that text.
fn cells_encoder() -> EncoderFor {
    Box::new(|columns| Box::new(CellsEncoder::new(columns, false)))
}

/// Whether every value of `row` has a text form, which a copy needs to
/// carry it.
fn has_text(columns: Option<&[ResultColumn]>, row: &[Value]) -> bool {
    let untyped = ColumnType::unknown();
    row.iter().enumerate().all(|(index, value)| {
        let column_type = columns
            .and_then(|columns| columns.get(index))
            .map_or(&untyped, |column| &column.column_type);
        matches!(edit_text(value, column_type), EditText::Editable(_))
    })
}

/// The texts of each row in the order of its numeric `id`, without the
/// `id`, leaving out the rows `skipped` names.
fn in_id_order(rows: &Rows<Kept>, skipped: &BTreeSet<String>) -> Vec<Vec<String>> {
    let id = rows.columns.iter().position(|name| name == "id");
    let mut ordered: Vec<(i64, Vec<String>)> = rows
        .by_id
        .iter()
        .filter(|(key, _)| !skipped.contains(*key))
        .filter_map(|(key, kept)| {
            let cells: Vec<String> = match kept {
                Kept::Texts(texts) => texts.iter().map(|text| quoted(text.as_deref())).collect(),
                Kept::Typed(cells) => cells
                    .iter()
                    .map(|cell| format!("{} {}", cell.kind, quoted(cell.text.as_deref())))
                    .collect(),
            };
            let cells = cells
                .into_iter()
                .enumerate()
                .filter(|(index, _)| Some(*index) != id)
                .map(|(_, cell)| cell)
                .collect();
            Some((key.parse().ok()?, cells))
        })
        .collect();
    ordered.sort_by_key(|(id, _)| *id);
    ordered.into_iter().map(|(_, cells)| cells).collect()
}

fn order_differences(what: &str, source: &[Vec<String>], copy: &[Vec<String>]) -> Vec<String> {
    let mut wrong = Vec::new();
    if source.len() != copy.len() {
        wrong.push(format!(
            "{what}: {} rows came back, {} were copied",
            copy.len(),
            source.len()
        ));
    }
    for (position, (expected, actual)) in source.iter().zip(copy).enumerate() {
        if expected != actual {
            wrong.push(format!(
                "{what}: row {} came back as ({}), copied as ({})",
                position + 1,
                actual.join(", "),
                expected.join(", ")
            ));
        }
    }
    wrong
}

/// Every corpus value exports as SQL INSERT, and the file, run in an
/// editor against an empty copy of its table, gives back the same rows,
/// each value of the same kind.
pub async fn sql_insert_export_runs_back_as_the_same_rows<E: ValueCorpusEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let corpus = engine.value_corpus();
    expect(SQL_CASE, !corpus.is_empty(), || "the engine lists no corpus".to_owned())?;
    let connection = connect(SQL_CASE, &engine, writable()).await?;
    let session = connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await?;
    let mut wrong = Vec::new();
    for (index, column) in corpus.iter().enumerate() {
        let source = match load(&engine, connection.as_ref(), &format!("sql_{index}"), column).await {
            Ok(table) => table,
            Err(failure) => {
                wrong.push(failure.to_string());
                continue;
            }
        };
        let what = format!("`{}` as SQL INSERT", column.declaration);
        let expected = read_rows(connection.as_ref(), &source, typed_texts, KeepValues::No).await?;
        let copy = corpus_table(&engine, connection.as_ref(), &format!("sql_{index}_copy"), column, &[]).await?;
        let generated = connection
            .fetch_columns(&source, within(CALL_DEADLINE))
            .await?
            .into_iter()
            .filter(|info| info.is_generated)
            .map(|info| info.name)
            .collect();
        let encoder = insert_encoder(connection.dialect(), copy.clone(), generated);
        let script = export_file(connection.as_ref(), &source, encoder).await?;
        let script = String::from_utf8(script).map_err(ConformanceFailure::setup)?;
        if let Some(failure) = run_script(session.as_ref(), &*connection.dialect(), &script).await? {
            wrong.push(format!("{what}: {failure}"));
            continue;
        }
        let actual = read_rows(connection.as_ref(), &copy, typed_texts, KeepValues::No).await?;
        wrong.extend(differences(&what, &expected, &actual, &BTreeSet::new()));
    }
    session.close().await;
    connection.close().await?;
    expect(SQL_CASE, wrong.is_empty(), || {
        format!(
            "{} differences after a SQL INSERT round trip:\n{}",
            wrong.len(),
            wrong.join("\n")
        )
    })
}

/// Run `script` as the editor runs a file: split by the engine's
/// grammar and sent a batch at a time. Returns why it stopped short.
async fn run_script(
    session: &dyn EditorSession,
    dialect: &dyn SqlDialect,
    script: &str,
) -> Result<Option<String>, ConformanceFailure> {
    let grammar = dialect.grammar();
    let plan = ScriptPlan::build(script, grammar, LexicalSettings::default_for(grammar));
    if let Some(diagnostic) = plan.diagnostics().first() {
        return Ok(Some(format!("the file does not split cleanly: {diagnostic:?}")));
    }
    for batch in plan.batches() {
        let text = script.get(batch.range.clone()).unwrap_or_default().trim();
        if text.is_empty() {
            continue;
        }
        for _ in 0..batch.repeat.get() {
            let (summary, _) = run_editor(session, text, run_options()).await?;
            if !summary.succeeded() {
                return Ok(Some(format!("`{text}` ended {:?}", summary.end)));
            }
        }
    }
    Ok(None)
}

/// A table whose CSV, under the export defaults, lands just under the
/// import's size limit imports back into an empty copy with every row
/// the same.
pub async fn csv_export_near_the_import_limit_imports_back<E: LargeTableEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let connection = connect(NEAR_LIMIT_CASE, &engine, writable()).await?;
    let source = create_scratch_table(&engine, connection.as_ref(), "near_limit").await?;
    let fill = engine.fill_scratch_table_sql(&source, NEAR_LIMIT_ROWS, NEAR_LIMIT_LABEL_WIDTH);
    apply_within(
        connection.as_ref(),
        &source,
        WriteKind::SchemaChanges,
        fill,
        FILL_DEADLINE,
    )
    .await?;
    let file = export_file(connection.as_ref(), &source, csv_encoder(CsvOptions::default())).await?;
    let size = file.len();
    expect(
        NEAR_LIMIT_CASE,
        size <= MAX_CSV_FILE_BYTES && size + NEAR_LIMIT_MARGIN > MAX_CSV_FILE_BYTES,
        || {
            format!(
                "the file is {size} bytes, not within {NEAR_LIMIT_MARGIN} under the {MAX_CSV_FILE_BYTES}-byte limit"
            )
        },
    )?;
    let copy = create_scratch_table(&engine, connection.as_ref(), "near_limit_copy").await?;
    import_csv(
        connection.as_ref(),
        &copy,
        &file,
        &CsvImportOptions::default(),
        within(NEAR_LIMIT_IMPORT_DEADLINE),
    )
    .await
    .map_err(|failure| unexpected(NEAR_LIMIT_CASE, format!("the import failed: {failure:?}")))?;
    drop(file);
    let expected = read_rows(connection.as_ref(), &source, digest, KeepValues::No).await?;
    let actual = read_rows(connection.as_ref(), &copy, digest, KeepValues::No).await?;
    connection.close().await?;
    expect(NEAR_LIMIT_CASE, expected.by_id.len() as u64 == NEAR_LIMIT_ROWS, || {
        format!("the table read {} rows, not {NEAR_LIMIT_ROWS}", expected.by_id.len())
    })?;
    let wrong = digest_differences(&expected, &actual);
    expect(NEAR_LIMIT_CASE, wrong.is_empty(), || wrong.join("\n"))
}

/// A writer's options and the reader's that match them. Each pairing
/// is meant to be lossless: NULL is written as a marker the reader takes
/// back, so an empty string stays one, and formulas are left as they
/// are. Between them they cover every delimiter, both quoting styles
/// that keep a delimiter inside a value, and every line break.
fn pairings() -> Vec<(CsvOptions, CsvImportOptions)> {
    [
        (CsvDelimiter::Comma, CsvQuote::IfNeeded, CsvLineBreak::Lf),
        (CsvDelimiter::Semicolon, CsvQuote::Always, CsvLineBreak::CrLf),
        (CsvDelimiter::Tab, CsvQuote::IfNeeded, CsvLineBreak::Cr),
        (CsvDelimiter::Pipe, CsvQuote::Always, CsvLineBreak::Lf),
    ]
    .into_iter()
    .map(|(delimiter, quote, line_break)| {
        let writer = CsvOptions {
            null_to_empty: false,
            sanitize_formulas: false,
            delimiter,
            quote,
            line_break,
            ..CsvOptions::default()
        };
        let reader = CsvImportOptions {
            delimiter,
            has_header: true,
            null_marker: NULL_MARKER.to_owned(),
        };
        (writer, reader)
    })
    .collect()
}

type EncoderFor = Box<dyn Fn(Arc<[ResultColumn]>) -> Box<dyn RowEncoder> + Send>;

fn csv_encoder(options: CsvOptions) -> EncoderFor {
    Box::new(move |columns| Box::new(CsvEncoder::new(columns, options.clone())))
}

/// INSERT statements into `table`, leaving out the columns the server
/// computes, as a table tab's export does.
fn insert_encoder(dialect: Arc<dyn SqlDialect>, table: TableRef, generated: Vec<String>) -> EncoderFor {
    Box::new(move |columns| Box::new(SqlInsertEncoder::new(dialect.clone(), &table, columns, &generated)))
}

/// Rows an export read, encoded one at a time from the columns the read
/// announced, as the export sink encodes them as they arrive. The app
/// writes a page the grid holds this way too.
fn encode(read: &ReadValues, encoder_for: &EncoderFor) -> Result<Vec<u8>, ConformanceFailure> {
    let columns = read
        .columns
        .clone()
        .ok_or_else(|| ConformanceFailure::setup("the export read started no result set"))?;
    let mut encoder = encoder_for(columns);
    let mut bytes = Vec::new();
    encoder.begin(&mut bytes);
    for row in &read.rows {
        encoder
            .row(&mut bytes, &mut row.iter())
            .map_err(|error| ConformanceFailure::setup(format!("the export failed: {error}")))?;
    }
    encoder.finish(&mut bytes);
    Ok(bytes)
}

/// Every row of `table` encoded by the encoder `encoder_for` builds, as
/// the export dialog's Entire Table writes it.
async fn export_file(
    connection: &dyn Connection,
    table: &TableRef,
    encoder_for: EncoderFor,
) -> Result<Vec<u8>, ConformanceFailure> {
    let file = Arc::new(Mutex::new(Encoded::default()));
    let sink = EncodingSink {
        file: Arc::clone(&file),
        encoder_for,
        encoder: None,
    };
    stream_table(connection, table, Box::new(sink)).await?;
    let file = std::mem::take(&mut *lock(&file));
    match file.failure {
        Some(failure) => Err(ConformanceFailure::setup(format!("the export failed: {failure}"))),
        None => Ok(file.bytes),
    }
}

/// Stream every row of `table` into `sink`: the statement `build_export`
/// writes, read at the precision the catalogue declares, as the export
/// dialog's Entire Table reads a table tab.
async fn stream_table(
    connection: &dyn Connection,
    table: &TableRef,
    sink: Box<dyn ResultSink>,
) -> Result<(), ConformanceFailure> {
    let columns: Arc<[ColumnInfo]> = connection.fetch_columns(table, within(CALL_DEADLINE)).await?.into();
    let identity = connection.row_identity(table, within(CALL_DEADLINE)).await?;
    let statement = build_export(
        &*connection.dialect(),
        &ExportRequest {
            table,
            columns: &columns,
            filter: &FilterSet::default(),
            sort: &[],
            identity: &identity,
        },
    )
    .map_err(ConformanceFailure::setup)?;
    connection
        .stream_read(
            &ReadStatement::Generated(statement),
            Box::new(DeclaredPrecisionSink::new(sink, columns)),
            within(EXPORT_DEADLINE),
        )
        .await?;
    Ok(())
}

#[derive(Default)]
struct Encoded {
    bytes: Vec<u8>,
    failure: Option<String>,
}

/// Encodes rows as they arrive, as the app's export sink does: the
/// encoder is built from the columns the stream announces.
struct EncodingSink {
    file: Arc<Mutex<Encoded>>,
    encoder_for: EncoderFor,
    encoder: Option<Box<dyn RowEncoder>>,
}

#[async_trait]
impl ResultSink for EncodingSink {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        let mut file = lock(&self.file);
        match event {
            ResultEvent::ResultSetStarted { columns } => {
                if self.encoder.is_some() {
                    file.failure = Some("a second result set started".to_owned());
                    return SinkFlow::ConsumerGone;
                }
                let mut encoder = (self.encoder_for)(columns);
                encoder.begin(&mut file.bytes);
                self.encoder = Some(encoder);
            }
            ResultEvent::Rows(rows) => {
                let Some(encoder) = self.encoder.as_mut() else {
                    file.failure = Some("rows arrived before their result set".to_owned());
                    return SinkFlow::ConsumerGone;
                };
                for row in &rows {
                    if let Err(error) = encoder.row(&mut file.bytes, &mut row.iter()) {
                        file.failure = Some(error.to_string());
                        return SinkFlow::ConsumerGone;
                    }
                }
            }
            ResultEvent::ResultSetFinished { .. } => {
                if let Some(encoder) = self.encoder.as_mut() {
                    encoder.finish(&mut file.bytes);
                }
            }
            _ => {}
        }
        SinkFlow::Continue
    }
}

/// A cell as the grid shows it, with the kind of value behind it.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct Cell {
    kind: &'static str,
    text: Option<String>,
}

/// What a comparison keeps of a row.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Kept {
    /// What the grid shows. CSV carries no kinds: a column SQLite types
    /// by its values takes an imported `42` as text.
    Texts(Vec<Option<String>>),
    /// The text and the kind of every value, which a SQL literal keeps.
    Typed(Vec<Cell>),
}

/// How a comparison keeps a row's cells.
type Keep = fn(Vec<Cell>) -> Kept;

fn texts(cells: Vec<Cell>) -> Kept {
    Kept::Texts(cells.into_iter().map(|cell| cell.text).collect())
}

fn typed_texts(cells: Vec<Cell>) -> Kept {
    Kept::Typed(cells)
}

/// The texts of a row, hashed, so a large table compares without
/// holding every row twice.
fn digest(cells: Vec<Cell>) -> u64 {
    let mut hasher = DefaultHasher::new();
    for cell in cells {
        cell.text.hash(&mut hasher);
    }
    hasher.finish()
}

/// Every row of a table by the text of its `id`.
struct Rows<T> {
    columns: Vec<String>,
    by_id: BTreeMap<String, T>,
    /// Rows holding a value with no text form the import reads back.
    without_text: BTreeSet<String>,
    duplicate: Option<String>,
    failure: Option<String>,
    values: ReadValues,
}

impl<T> Default for Rows<T> {
    fn default() -> Self {
        Self {
            columns: Vec::new(),
            by_id: BTreeMap::new(),
            without_text: BTreeSet::new(),
            duplicate: None,
            failure: None,
            values: ReadValues::default(),
        }
    }
}

/// The values a read sent, under the columns its result set started
/// with, which are the ones the export sink builds its encoder from.
#[derive(Default)]
struct ReadValues {
    columns: Option<Arc<[ResultColumn]>>,
    rows: Vec<Vec<Value>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum KeepValues {
    Yes,
    No,
}

/// Every row of `table`, read as an export reads it and kept by `keep`,
/// with the values themselves when `values` says so.
async fn read_rows<T: Send + 'static>(
    connection: &dyn Connection,
    table: &TableRef,
    keep: fn(Vec<Cell>) -> T,
    values: KeepValues,
) -> Result<Rows<T>, ConformanceFailure> {
    let read = Arc::new(Mutex::new(Rows::default()));
    let sink = RowSink {
        read: Arc::clone(&read),
        keep,
        values,
        columns: None,
        id: None,
    };
    stream_table(connection, table, Box::new(sink)).await?;
    let rows = std::mem::take(&mut *lock(&read));
    match rows.failure {
        Some(failure) => Err(ConformanceFailure::setup(failure)),
        None => Ok(rows),
    }
}

struct RowSink<T> {
    read: Arc<Mutex<Rows<T>>>,
    keep: fn(Vec<Cell>) -> T,
    values: KeepValues,
    columns: Option<Arc<[ResultColumn]>>,
    id: Option<usize>,
}

#[async_trait]
impl<T: Send + 'static> ResultSink for RowSink<T> {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        let mut read = lock(&self.read);
        match event {
            ResultEvent::ResultSetStarted { columns } | ResultEvent::ColumnsResolved { columns, .. } => {
                if read.values.columns.is_none() {
                    read.values.columns = Some(Arc::clone(&columns));
                }
                self.id = columns.iter().position(|column| column.name == "id");
                read.columns = columns.iter().map(|column| column.name.clone()).collect();
                self.columns = Some(columns);
            }
            ResultEvent::Rows(rows) => {
                let (Some(columns), Some(id)) = (&self.columns, self.id) else {
                    read.failure = Some(format!("no `id` column in {:?}", read.columns));
                    return SinkFlow::ConsumerGone;
                };
                let untyped = ColumnType::unknown();
                for row in rows {
                    let column_type = |index: usize| columns.get(index).map_or(&untyped, |column| &column.column_type);
                    let has_text = row
                        .iter()
                        .enumerate()
                        .all(|(index, value)| matches!(edit_text(value, column_type(index)), EditText::Editable(_)));
                    let cells: Vec<Cell> = row
                        .iter()
                        .enumerate()
                        .map(|(index, value)| Cell {
                            kind: value.variant_name(),
                            text: shown(value, column_type(index)),
                        })
                        .collect();
                    let key = cells.get(id).and_then(|cell| cell.text.clone()).unwrap_or_default();
                    if self.values == KeepValues::Yes {
                        read.values.rows.push(row);
                    }
                    if !has_text {
                        read.without_text.insert(key.clone());
                    }
                    if read.by_id.insert(key.clone(), (self.keep)(cells)).is_some() {
                        read.duplicate.get_or_insert(key);
                    }
                }
            }
            _ => {}
        }
        SinkFlow::Continue
    }
}

/// Every way `copy` differs from `source`, one line each, leaving out
/// the rows `skipped` names.
fn differences(what: &str, source: &Rows<Kept>, copy: &Rows<Kept>, skipped: &BTreeSet<String>) -> Vec<String> {
    let mut wrong = Vec::new();
    if copy.columns != source.columns {
        wrong.push(format!(
            "{what}: the copy has the columns {:?}, the table {:?}",
            copy.columns, source.columns
        ));
    }
    if let Some(id) = &copy.duplicate {
        wrong.push(format!("{what}: row {id} came back twice"));
    }
    let kept = |rows: &Rows<Kept>| rows.by_id.keys().filter(|id| !skipped.contains(*id)).count();
    let (exported, imported) = (kept(source), kept(copy));
    if exported != imported {
        wrong.push(format!("{what}: {imported} rows came back, {exported} were exported"));
    }
    for (id, expected) in source.by_id.iter().filter(|(id, _)| !skipped.contains(*id)) {
        let Some(actual) = copy.by_id.get(id) else {
            wrong.push(format!("{what}: row {id} did not come back"));
            continue;
        };
        if actual != expected {
            wrong.push(format!(
                "{what}: row {id} came back as {}, exported as {}",
                described(actual),
                described(expected)
            ));
        }
    }
    for id in copy.by_id.keys().filter(|id| !skipped.contains(*id)) {
        if !source.by_id.contains_key(id) {
            wrong.push(format!("{what}: row {id} came back but was never exported"));
        }
    }
    wrong
}

fn described(kept: &Kept) -> String {
    let cells: Vec<String> = match kept {
        Kept::Texts(texts) => texts.iter().map(|text| quoted(text.as_deref())).collect(),
        Kept::Typed(cells) => cells
            .iter()
            .map(|cell| format!("{} {}", cell.kind, quoted(cell.text.as_deref())))
            .collect(),
    };
    format!("({})", cells.join(", "))
}

/// The rows of a large table that did not come back the same, the
/// first few of each kind by `id`.
fn digest_differences(source: &Rows<u64>, copy: &Rows<u64>) -> Vec<String> {
    let missing: Vec<&String> = source.by_id.keys().filter(|id| !copy.by_id.contains_key(*id)).collect();
    let extra: Vec<&String> = copy.by_id.keys().filter(|id| !source.by_id.contains_key(*id)).collect();
    let changed: Vec<&String> = source
        .by_id
        .iter()
        .filter(|(id, digest)| copy.by_id.get(*id).is_some_and(|other| other != *digest))
        .map(|(id, _)| id)
        .collect();
    let mut wrong = Vec::new();
    if let Some(id) = &copy.duplicate {
        wrong.push(format!("row {id} came back twice"));
    }
    for (count, ids, says) in [
        (missing.len(), &missing, "did not come back"),
        (extra.len(), &extra, "came back but were never exported"),
        (changed.len(), &changed, "came back changed"),
    ] {
        if count > 0 {
            let listed: Vec<&str> = ids.iter().take(LISTED_IDS).map(|id| id.as_str()).collect();
            wrong.push(format!("{count} rows {says}, among them {}", listed.join(", ")));
        }
    }
    wrong
}
