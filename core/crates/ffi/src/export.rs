use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use async_trait::async_trait;
use tablepro_core::browse::{DeclaredPrecisionSink, ExportFields, ExportRequest, SortKey, build_export};
use tablepro_core::column::{ColumnKind, ColumnType, ResultColumn};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::edit::parse_filter_text;
use tablepro_core::export::{
    CsvEncoder, CsvOptions, EncodeError, HtmlEncoder, JsonArrayEncoder, MarkdownEncoder, RenderError, RowEncoder,
    SqlInsertEncoder, XLSX_MAX_DATA_ROWS, XlsxSheetWriter, XmlEncoder,
};
use tablepro_core::filter::FilterSet;
use tablepro_core::masking::{ColumnMasks, MaskingScope, MaskingSink};
use tablepro_core::meta::{RowIdentity, TableRef};
use tablepro_core::value::{JsonText, OtherValue, UndecodableReason, UndecodedValue};
use tablepro_core::{ColumnInfo, ReadStatement, ResultEvent, ResultSink, SinkFlow, Truncation, Value};
use tablepro_session::OperationKind;
use tablepro_session::runtime::Tasks;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::cancel_token::{CancelToken, token};
use crate::catalog::TableName;
use crate::error::CoreError;
use crate::filter::{TableFilterArg, filter_set};
use crate::results::{ResultSet, ValueKind};
use crate::runtime::on_runtime;
use crate::session::{ColumnSort, DatabaseSession, sort_keys};

// Written a chunk at a time, so neither a row nor the whole result is one write.
const CHUNK_BYTES: usize = 64 * 1024;
// Held rows encoded between two looks at the cancel.
const ROWS_PER_BATCH: u64 = 1_024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ExportFormatTag {
    Csv,
    Json,
    Excel,
    Markdown,
    Html,
    Xml,
    SqlInsert,
}

#[uniffi::export]
impl DatabaseSession {
    // Only the first `visible_columns` columns, since a table page carries row addresses after them.
    pub async fn export_rows(
        &self,
        rows: Arc<ResultSet>,
        visible_columns: u32,
        format: ExportFormatTag,
        table: Option<TableName>,
        path: String,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<u64, CoreError> {
        let session = self.session().clone();
        let tasks = self.tasks().clone();
        let cancel = token(cancel);
        on_runtime(self.tasks(), async move {
            let target = destination(&path)?;
            // A set still reading would write the rows held so far as if they were all of them.
            if !rows.is_finished() {
                return Err(CoreError::failed(
                    "ffi.export_unfinished",
                    "the rows are still arriving",
                ));
            }
            let table = table.map(TableRef::from);
            if format == ExportFormatTag::Excel && rows.row_count() > XLSX_MAX_DATA_ROWS as u64 {
                return Err(sheet_full());
            }
            let insert = match (format, &table) {
                (ExportFormatTag::SqlInsert, None) => return Err(needs_table()),
                (ExportFormatTag::SqlInsert, Some(table)) => {
                    let columns = tokio::select! {
                        biased;
                        () = cancel.cancelled() => return Err(CoreError::Cancelled),
                        columns = session.columns(table.clone()) => columns?,
                    };
                    Some(InsertTarget::of(table, &columns))
                }
                _ => None,
            };
            let recipe = Recipe {
                format,
                title: title(table.as_ref(), &target),
                insert,
            };
            let held = rows.result_columns();
            let visible = usize::try_from(visible_columns).unwrap_or(usize::MAX).min(held.len());
            let columns: Arc<[ResultColumn]> = held.iter().take(visible).cloned().collect();
            // Masked by the connection's rules, also for a tab the user revealed: a table's page by the table, a
            // query's result by what each column reads.
            let overlay = rows.shown_masks().overlay(&rows.external_masks(&columns));
            let part = Arc::new(PartFile::beside(target)?);
            let ending = Ending::default();
            let mut sink = FileSink::new(
                recipe,
                session.current_dialect(),
                part.clone(),
                tasks.clone(),
                ending.clone(),
            );
            let fed = feed(&mut sink, &rows, &columns, &overlay, &cancel).await;
            drop(sink);
            settle(part, &tasks, &ending, fed).await
        })
        .await
    }

    // Every row the filter selects, in the sort's order, streamed to the file on a connection of the read's own.
    pub async fn export_table(
        &self,
        table: TableName,
        sort: Option<ColumnSort>,
        filter: Option<TableFilterArg>,
        format: ExportFormatTag,
        path: String,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<u64, CoreError> {
        let session = self.session().clone();
        let tasks = self.tasks().clone();
        let cancel = token(cancel);
        on_runtime(self.tasks(), async move {
            let target = destination(&path)?;
            let table: TableRef = table.into();
            let dialect = session.current_dialect().ok_or_else(not_connected)?;
            let filter = filter_set(filter, &*dialect)?;
            let columns = tokio::select! {
                biased;
                () = cancel.cancelled() => return Err(CoreError::Cancelled),
                columns = session.columns(table.clone()) => columns?,
            };
            let identity = session
                .run_cancellable(OperationKind::Metadata, &cancel, |lease, options| {
                    let table = table.clone();
                    async move { Ok(lease.row_identity(&table, options).await?) }
                })
                .await?;
            let recipe = Recipe {
                format,
                title: title(Some(&table), &target),
                insert: (format == ExportFormatTag::SqlInsert).then(|| InsertTarget::of(&table, &columns)),
            };
            let masking = MaskingScope::External {
                table: Some(tablepro_core::masking::table_name(&table)),
            };
            let policy = session.masking_policy();
            let read = Arc::new(TableRead {
                table,
                columns,
                filter,
                sort: sort_keys(sort),
                identity,
            });
            let part = Arc::new(PartFile::beside(target)?);
            let ending = Ending::default();
            let streamed = session
                .run_cancellable(OperationKind::Export, &cancel, |lease, options| {
                    let read = read.clone();
                    let sink = FileSink::new(
                        recipe.clone(),
                        Some(lease.dialect()),
                        part.clone(),
                        tasks.clone(),
                        ending.clone(),
                    );
                    // After the declared precision, so a mask reads the value as the file would have held it.
                    let sink = MaskingSink::wrap(Box::new(sink), policy.clone(), masking.clone());
                    async move {
                        let statement = build_export(&*lease.dialect(), &read.request())?;
                        let sink = DeclaredPrecisionSink::new(sink, read.columns.clone());
                        Ok(lease
                            .stream_read(&ReadStatement::Generated(statement), Box::new(sink), options)
                            .await?)
                    }
                })
                .await;
            settle(part, &tasks, &ending, streamed.map(|_| ()).map_err(CoreError::from)).await
        })
        .await
    }
}

struct TableRead {
    table: TableRef,
    columns: Arc<[ColumnInfo]>,
    filter: FilterSet,
    sort: Vec<SortKey>,
    identity: RowIdentity,
}

impl TableRead {
    fn request(&self) -> ExportRequest<'_> {
        ExportRequest {
            table: &self.table,
            columns: &self.columns,
            filter: &self.filter,
            sort: &self.sort,
            identity: &self.identity,
            fields: ExportFields::Every,
        }
    }
}

#[derive(Clone)]
struct Recipe {
    format: ExportFormatTag,
    title: String,
    insert: Option<InsertTarget>,
}

#[derive(Clone)]
struct InsertTarget {
    table: TableRef,
    // Computed by the server, so the statements leave them out.
    generated: Vec<String>,
    // Numbered by the server, so they keep their values through the engine's override.
    numbered: Vec<String>,
}

impl InsertTarget {
    fn of(table: &TableRef, columns: &[ColumnInfo]) -> Self {
        Self {
            table: table.clone(),
            generated: columns
                .iter()
                .filter(|column| column.is_generated)
                .map(|column| column.name.clone())
                .collect(),
            numbered: columns
                .iter()
                .filter(|column| column.is_auto_increment)
                .map(|column| column.name.clone())
                .collect(),
        }
    }
}

enum Writer {
    Rows(Box<dyn RowEncoder>),
    // A workbook is a zip archive, written whole once the last row is in; its sheet spills rows to disk meanwhile.
    Sheet(Box<XlsxSheetWriter>),
}

impl Recipe {
    // The columns are the ones the read announced, which are the ones its rows carry.
    fn writer(&self, columns: Arc<[ResultColumn]>, dialect: Option<Arc<dyn SqlDialect>>) -> Result<Writer, CoreError> {
        let encoder: Box<dyn RowEncoder> = match self.format {
            ExportFormatTag::Csv => Box::new(CsvEncoder::new(columns, CsvOptions::default())),
            ExportFormatTag::Json => Box::new(JsonArrayEncoder::new(columns)),
            ExportFormatTag::Markdown => Box::new(MarkdownEncoder::new(columns)),
            ExportFormatTag::Html => Box::new(HtmlEncoder::new(columns, self.title.clone())),
            ExportFormatTag::Xml => Box::new(XmlEncoder::new(columns)),
            ExportFormatTag::Excel => {
                let sheet = XlsxSheetWriter::new(columns, &self.title).map_err(render_error)?;
                return Ok(Writer::Sheet(Box::new(sheet)));
            }
            ExportFormatTag::SqlInsert => {
                let target = self.insert.as_ref().ok_or_else(needs_table)?;
                let dialect = dialect.ok_or_else(not_connected)?;
                Box::new(SqlInsertEncoder::new(
                    dialect,
                    &target.table,
                    columns,
                    &target.generated,
                    &target.numbered,
                ))
            }
        };
        Ok(Writer::Rows(encoder))
    }
}

// The rows written, or why the sink stopped, which explains a read that ended early better than the read can.
type Ending = Arc<Mutex<Option<Result<u64, CoreError>>>>;

// File work runs on the blocking pool, so a slow disk never holds a runtime thread.
struct FileSink {
    recipe: Recipe,
    dialect: Option<Arc<dyn SqlDialect>>,
    part: Arc<PartFile>,
    tasks: Tasks,
    ending: Ending,
    file: Option<File>,
    writer: Option<Writer>,
    buffer: Vec<u8>,
    rows: u64,
    sets: u32,
}

impl FileSink {
    fn new(
        recipe: Recipe,
        dialect: Option<Arc<dyn SqlDialect>>,
        part: Arc<PartFile>,
        tasks: Tasks,
        ending: Ending,
    ) -> Self {
        Self {
            recipe,
            dialect,
            part,
            tasks,
            ending,
            file: None,
            writer: None,
            buffer: Vec::with_capacity(CHUNK_BYTES),
            rows: 0,
            sets: 0,
        }
    }

    async fn start(&mut self, columns: Arc<[ResultColumn]>) -> Result<(), CoreError> {
        self.sets += 1;
        // A file holds one result, and a second would come out glued to the first.
        if self.sets > 1 {
            return Err(CoreError::failed(
                "ffi.export_several_results",
                "the read returned more than one result",
            ));
        }
        let recipe = self.recipe.clone();
        let dialect = self.dialect.clone();
        let part = self.part.clone();
        let (file, mut writer) = blocking(&self.tasks, move || {
            let file = File::create(&part.path).map_err(|error| io_error(&part.target, &error))?;
            Ok((file, recipe.writer(columns, dialect)?))
        })
        .await?;
        if let Writer::Rows(encoder) = &mut writer {
            encoder.begin(&mut self.buffer);
        }
        self.file = Some(file);
        self.writer = Some(writer);
        Ok(())
    }

    async fn take(&mut self, rows: Vec<Vec<Value>>) -> Result<(), CoreError> {
        match self.writer.take() {
            Some(Writer::Rows(mut encoder)) => {
                let encoded = self.encode(&mut *encoder, &rows).await;
                self.writer = Some(Writer::Rows(encoder));
                encoded
            }
            Some(Writer::Sheet(mut sheet)) => {
                let count = rows.len() as u64;
                let sheet = blocking(&self.tasks, move || {
                    sheet.write_rows(&rows).map_err(render_error)?;
                    Ok(sheet)
                })
                .await?;
                self.writer = Some(Writer::Sheet(sheet));
                self.rows += count;
                Ok(())
            }
            None => Err(CoreError::failed(
                "ffi.export_failed",
                "rows arrived before their result",
            )),
        }
    }

    async fn encode(&mut self, encoder: &mut dyn RowEncoder, rows: &[Vec<Value>]) -> Result<(), CoreError> {
        for row in rows {
            encoder.row(&mut self.buffer, &mut row.iter()).map_err(encode_error)?;
            self.rows += 1;
            if self.buffer.len() >= CHUNK_BYTES {
                self.flush().await?;
            }
        }
        Ok(())
    }

    async fn flush(&mut self) -> Result<(), CoreError> {
        if self.buffer.is_empty() {
            return Ok(());
        }
        let mut file = self.file.take().ok_or_else(file_gone)?;
        let bytes = std::mem::take(&mut self.buffer);
        let part = self.part.clone();
        let (file, mut bytes) = blocking(&self.tasks, move || {
            file.write_all(&bytes).map_err(|error| io_error(&part.target, &error))?;
            Ok((file, bytes))
        })
        .await?;
        bytes.clear();
        self.buffer = bytes;
        self.file = Some(file);
        Ok(())
    }

    async fn finish(&mut self) -> Result<u64, CoreError> {
        match self.writer.take() {
            Some(Writer::Rows(mut encoder)) => encoder.finish(&mut self.buffer),
            Some(Writer::Sheet(sheet)) => {
                self.buffer = blocking(&self.tasks, move || {
                    XlsxSheetWriter::finish(*sheet).map_err(render_error)
                })
                .await?;
            }
            None => return Err(no_result()),
        }
        self.flush().await?;
        let file = self.file.take().ok_or_else(file_gone)?;
        let part = self.part.clone();
        // On disk before the rename, so the name never points at a file still short of its rows.
        blocking(&self.tasks, move || {
            file.sync_all().map_err(|error| io_error(&part.target, &error))
        })
        .await?;
        Ok(self.rows)
    }

    // A failure is kept over a finish, since a second result after the first one fails the export.
    fn end(&self, ending: Result<u64, CoreError>) {
        let mut slot = self.ending.lock().unwrap_or_else(PoisonError::into_inner);
        if !matches!(*slot, Some(Err(_))) {
            *slot = Some(ending);
        }
    }
}

#[async_trait]
impl ResultSink for FileSink {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        let step = match event {
            ResultEvent::ResultSetStarted { columns } => self.start(columns).await,
            ResultEvent::Rows(rows) => self.take(rows).await,
            ResultEvent::ResultSetFinished { .. } => self.finish().await.map(|rows| self.end(Ok(rows))),
            _ => Ok(()),
        };
        match step {
            Ok(()) => SinkFlow::Continue,
            Err(error) => {
                self.end(Err(error));
                SinkFlow::ConsumerGone
            }
        }
    }
}

// The rows a set holds, through the same sink a streamed read feeds, so both write the same bytes.
async fn feed(
    sink: &mut FileSink,
    set: &ResultSet,
    columns: &Arc<[ResultColumn]>,
    overlay: &ColumnMasks,
    cancel: &CancellationToken,
) -> Result<(), CoreError> {
    let total = set.row_count();
    let started = ResultEvent::ResultSetStarted {
        columns: columns.clone(),
    };
    if sink.accept(started).await == SinkFlow::ConsumerGone {
        return Ok(());
    }
    let mut next = 0;
    while next < total {
        if cancel.is_cancelled() {
            return Err(CoreError::Cancelled);
        }
        let end = total.min(next + ROWS_PER_BATCH);
        let mut batch: Vec<Vec<Value>> = (next..end).map(|row| held_row(set, row, columns)).collect();
        overlay.apply_rows(columns, &mut batch);
        if sink.accept(ResultEvent::Rows(batch)).await == SinkFlow::ConsumerGone {
            return Ok(());
        }
        next = end;
    }
    if cancel.is_cancelled() {
        return Err(CoreError::Cancelled);
    }
    let finished = ResultEvent::ResultSetFinished {
        retained: total,
        total_rows: Some(total),
        truncation: Truncation::Complete,
    };
    sink.accept(finished).await;
    Ok(())
}

pub(crate) fn held_row(set: &ResultSet, row: u64, columns: &[ResultColumn]) -> Vec<Value> {
    columns
        .iter()
        .enumerate()
        .map(|(index, column)| held_value(set, row, index, column))
        .collect()
}

// The value where the store kept it exactly, else read back from the text the core's export wrote for it on arrival.
pub(crate) fn held_value(set: &ResultSet, row: u64, index: usize, column: &ResultColumn) -> Value {
    if let Some(value) = set.stored_value(row, index) {
        return value;
    }
    let text = set.full_text(row, index).flatten().unwrap_or_default();
    let other = |text: String| {
        Value::Other(Box::new(OtherValue {
            type_name: column.column_type.name.clone(),
            text,
        }))
    };
    match set.cell_kind(row, index).flatten() {
        Some(ValueKind::Float) => match text.parse::<f64>() {
            Ok(number) => Value::Float64(number),
            Err(_) => other(text),
        },
        Some(ValueKind::Json) => match JsonText::parse(text.clone()) {
            Ok(json) => Value::Json(json),
            Err(_) => other(text),
        },
        Some(ValueKind::Array) => array_value(&text, &column.column_type).unwrap_or_else(|| other(text)),
        // Refused by every encoder, as a streamed export refuses it.
        Some(ValueKind::Undecodable) => Value::Undecodable(Box::new(UndecodedValue {
            type_name: column.column_type.name.clone(),
            reason: UndecodableReason::UnsupportedType,
        })),
        _ => other(text),
    }
}

// The store keeps an array as JSON whose items are each element's text (`value_text`), so each is read back by the
// element's kind: a number stays a number and a binary value its bytes, as a streamed read gives them.
fn array_value(text: &str, column: &ColumnType) -> Option<Value> {
    items(&serde_json::from_str(text).ok()?, &element_of(column))
}

fn items(json: &serde_json::Value, element: &ColumnType) -> Option<Value> {
    let serde_json::Value::Array(list) = json else {
        return None;
    };
    list.iter()
        .map(|item| match item {
            serde_json::Value::Null => Some(Value::Null),
            serde_json::Value::String(text) => {
                Some(parse_filter_text(text, element).unwrap_or_else(|_| Value::Text(text.clone())))
            }
            // An inner dimension, which a declared kind such as PostgreSQL's int4[][] does not name again.
            serde_json::Value::Array(_) => items(item, &element_of(element)),
            _ => None,
        })
        .collect::<Option<Vec<_>>>()
        .map(Value::Array)
}

fn element_of(column: &ColumnType) -> ColumnType {
    match &column.kind {
        ColumnKind::Array { element } => ColumnType {
            kind: (**element).clone(),
            ..column.clone()
        },
        _ => column.clone(),
    }
}

// The sink's own failure explains why the read stopped, so it goes before the read's.
async fn settle(
    part: Arc<PartFile>,
    tasks: &Tasks,
    ending: &Ending,
    read: Result<(), CoreError>,
) -> Result<u64, CoreError> {
    let ended = ending.lock().unwrap_or_else(PoisonError::into_inner).take();
    let rows = match (ended, read) {
        (Some(Err(error)), _) | (_, Err(error)) => return Err(error),
        (Some(Ok(rows)), Ok(())) => rows,
        (None, Ok(())) => return Err(no_result()),
    };
    blocking(tasks, move || part.place()).await?;
    Ok(rows)
}

// Removed by whoever lets go of it last unless put in place, so a sink still finishing cannot leave it behind.
struct PartFile {
    path: PathBuf,
    target: PathBuf,
    placed: AtomicBool,
}

impl PartFile {
    fn beside(target: PathBuf) -> Result<Self, CoreError> {
        let name = target
            .file_name()
            .ok_or_else(|| bad_path(&target))?
            .to_string_lossy()
            .into_owned();
        Ok(Self {
            path: target.with_file_name(format!(".{name}.{}.part", Uuid::new_v4().simple())),
            target,
            placed: AtomicBool::new(false),
        })
    }

    // A rename replaces the file that was there in one step.
    fn place(&self) -> Result<(), CoreError> {
        std::fs::rename(&self.path, &self.target).map_err(|error| io_error(&self.target, &error))?;
        self.placed.store(true, Ordering::Release);
        Ok(())
    }
}

impl Drop for PartFile {
    fn drop(&mut self) {
        if *self.placed.get_mut() {
            return;
        }
        match std::fs::remove_file(&self.path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => tracing::warn!(%error, "could not remove an unfinished export"),
        }
    }
}

async fn blocking<T, F>(tasks: &Tasks, work: F) -> Result<T, CoreError>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, CoreError> + Send + 'static,
{
    tasks
        .spawn_blocking_task(work)
        .await
        .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))?
}

fn destination(path: &str) -> Result<PathBuf, CoreError> {
    let target = PathBuf::from(path);
    match target.is_absolute() && target.file_name().is_some() {
        true => Ok(target),
        false => Err(bad_path(&target)),
    }
}

fn title(table: Option<&TableRef>, target: &Path) -> String {
    match table {
        Some(table) => table.name.clone(),
        None => target
            .file_stem()
            .map(|stem| stem.to_string_lossy().into_owned())
            .unwrap_or_default(),
    }
}

fn io_error(path: &Path, error: &std::io::Error) -> CoreError {
    let mut failed = CoreError::failed("ffi.export_io", format!("{}: {error}", path.display()));
    if let CoreError::Failed { info } = &mut failed {
        info.path = Some(path.display().to_string());
    }
    failed
}

fn render_error(error: RenderError) -> CoreError {
    let code = match &error {
        RenderError::TooManyRows { .. } => "ffi.export_sheet_full",
        RenderError::TooManyColumns { .. } => "ffi.export_sheet_too_wide",
        RenderError::TextTooLong { .. } => "ffi.export_cell_too_long",
        RenderError::Encode(encode) => return encode_error(encode.clone()),
        RenderError::Csv(_) | RenderError::Flush(_) | RenderError::Utf8(_) | RenderError::Xlsx(_) => {
            "ffi.export_failed"
        }
    };
    CoreError::failed(code, error.to_string())
}

fn encode_error(error: EncodeError) -> CoreError {
    let code = match &error {
        EncodeError::Undecodable { .. } => "ffi.export_undecodable",
        EncodeError::NotXmlText { .. } => "ffi.export_not_xml_text",
    };
    CoreError::failed(code, error.to_string())
}

fn bad_path(path: &Path) -> CoreError {
    CoreError::failed(
        "ffi.export_bad_path",
        format!("{} is not an absolute file path", path.display()),
    )
}

fn needs_table() -> CoreError {
    CoreError::failed(
        "ffi.export_needs_table",
        "SQL INSERT needs the table the rows came from",
    )
}

fn sheet_full() -> CoreError {
    CoreError::failed(
        "ffi.export_sheet_full",
        format!("a sheet holds {XLSX_MAX_DATA_ROWS} rows"),
    )
}

fn no_result() -> CoreError {
    CoreError::failed("ffi.export_no_result", "the read ended before its result did")
}

fn file_gone() -> CoreError {
    CoreError::failed("ffi.export_failed", "the export's file was closed early")
}

fn not_connected() -> CoreError {
    CoreError::failed("ffi.not_connected", "the session has no connection")
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{IntegerKind, IntegerWidth, ReadForm, TextLength};
    use tablepro_core::export::{ResultExtent, build_snapshot};

    use super::*;
    use crate::results::ResultStore;

    fn array_of(name: &str, element: ColumnKind) -> ResultColumn {
        ResultColumn::new(
            name,
            ColumnType {
                name: format!("{name}[]"),
                kind: ColumnKind::Array {
                    element: Box::new(element),
                },
                catalog: None,
                dynamic_storage: false,
                read_form: ReadForm::Native,
            },
        )
    }

    fn bigint() -> ColumnKind {
        ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W64,
            signed: true,
        })
    }

    // A held row of one masked column, `email`, holding ann's address and NULL.
    fn masked_set(style: Option<tablepro_core::masking::MaskingStyle>) -> ResultSet {
        use tablepro_core::masking::{MaskingPolicy, MaskingRule, MaskingTarget, SharedMaskingPolicy};

        use crate::results::GridMasking;

        let columns: Arc<[ResultColumn]> = vec![ResultColumn::new("email", ColumnType::untyped_text("text"))].into();
        let rules = style.map(|style| MaskingRule::new("email", MaskingTarget::Column, style));
        let store = Arc::new(ResultStore::with_masking(
            columns,
            Some(GridMasking {
                policy: SharedMaskingPolicy::new(MaskingPolicy::new(rules)),
                named_table: None,
                own_table: None,
                visible: None,
                revealed: false,
            }),
        ));
        store.append(&[vec![Value::Text("ann@example.com".to_owned())], vec![Value::Null]]);
        store.finish();
        ResultSet::new(0, store)
    }

    #[test]
    fn a_null_in_a_masked_column_reads_back_as_null_under_every_style() {
        use tablepro_core::masking::MaskingStyle;

        for style in MaskingStyle::ALL {
            let set = masked_set(Some(style));
            let columns = set.result_columns();

            assert_eq!(held_row(&set, 1, &columns), [Value::Null], "{style:?}");
            let first = held_row(&set, 0, &columns);
            assert_ne!(
                first,
                [Value::Text("ann@example.com".to_owned())],
                "{style:?} showed the value"
            );
        }
    }

    #[test]
    fn a_null_stays_null_under_an_overlay_laid_on_held_rows() {
        use tablepro_core::masking::{ColumnMasks, MaskingStyle};

        let shown = masked_set(Some(MaskingStyle::Email));
        let plain = masked_set(None);
        for (set, external) in [(&shown, MaskingStyle::LastFour), (&plain, MaskingStyle::Full)] {
            let columns = set.result_columns();
            let overlay = set.shown_masks().overlay(&ColumnMasks::new(vec![Some(external)]));
            let mut rows = vec![held_row(set, 0, &columns), held_row(set, 1, &columns)];

            overlay.apply_rows(&columns, &mut rows);

            assert_eq!(rows[0], [Value::Text("••••".to_owned())], "{external:?}");
            assert_eq!(rows[1], [Value::Null], "{external:?}");
        }
    }

    #[test]
    fn an_array_comes_back_element_by_element_as_a_streamed_read_gives_it() {
        let columns: Arc<[ResultColumn]> = vec![
            array_of("ids", bigint()),
            array_of(
                "blobs",
                ColumnKind::Bytes {
                    length: TextLength::Unbounded,
                },
            ),
            array_of("grid", bigint()),
        ]
        .into();
        let row = vec![
            Value::Array(vec![Value::Int(1), Value::Int(9_007_199_254_740_993), Value::Null]),
            Value::Array(vec![Value::Bytes(vec![0xca, 0xfe])]),
            Value::Array(vec![
                Value::Array(vec![Value::Int(1), Value::Int(2)]),
                Value::Array(vec![Value::Int(3), Value::Int(4)]),
            ]),
        ];
        let store = Arc::new(ResultStore::new(columns.clone()));
        store.append(std::slice::from_ref(&row));
        store.finish();
        let set = ResultSet::new(0, store);

        let held = held_row(&set, 0, &columns);
        let snapshot = build_snapshot(&columns, [held.clone()], ResultExtent::complete(1), 10);

        assert_eq!(held, row);
        let cells: Vec<&str> = snapshot.rows[0].iter().map(|cell| cell.get()).collect();
        assert_eq!(
            cells,
            ["[1,9007199254740993,null]", r#"["(binary, 2 bytes)"]"#, "[[1,2],[3,4]]"]
        );
    }

    #[test]
    fn an_array_whose_text_does_not_read_back_stays_its_text() {
        let column = array_of("odd", bigint());

        let value = array_value("{1,2,3}", &column.column_type);

        assert_eq!(value, None);
    }
}
