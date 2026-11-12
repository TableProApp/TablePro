use std::sync::Arc;

use async_trait::async_trait;
use thiserror::Error;
use tokio::sync::mpsc;

use crate::browse::{BrowseSqlError, DeclaredPrecisionSink, ExportFields, ExportRequest, build_export};
use crate::call_options::CallOptions;
use crate::column::{ColumnInfo, ResultColumn};
use crate::connection::Connection;
use crate::dialect::{DatabaseLayout, SqlDialect};
use crate::error::DriverError;
use crate::filter::FilterSet;
use crate::meta::TableRef;
use crate::read_statement::ReadStatement;
use crate::result_event::ResultEvent;
use crate::result_sink::{ResultSink, SinkFlow};
use crate::unsupported_feature::UnsupportedFeature;
use crate::value::Value;

use super::dump_order::{creation_order, order_tables};
use super::insert_batch::InsertBatch;
use super::{
    DumpCatalog, DumpDialect, DumpObject, DumpObjectKind, DumpScope, DumpSection, DumpSkip, DumpSkipReason,
    DumpStatement, DumpTable,
};

/// Chunks between a table's read and the file. Few, so a slow disk holds
/// the read back.
const CHUNKS_IN_FLIGHT: usize = 4;

/// Text a chunk holds before it goes to the file.
const CHUNK_BYTES: usize = 256 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DumpRequest {
    pub scope: DumpScope,
    /// Whether the tables' rows go in, or only their structure.
    pub data: bool,
}

/// Where a dump's bytes go.
#[async_trait]
pub trait DumpOutput: Send {
    async fn write(&mut self, bytes: Vec<u8>) -> Result<(), DumpOutputClosed>;

    fn progress(&mut self, _progress: DumpProgress) {}
}

/// The file stopped taking bytes, and said why where it was written.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DumpOutputClosed;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DumpProgress {
    pub tables_done: usize,
    pub tables_total: usize,
    pub rows: u64,
}

/// Values with no SQL literal on the engine, written as NULL.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OmittedValues {
    pub table: TableRef,
    pub column: String,
    pub count: u64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DumpReport {
    pub tables: usize,
    pub rows: u64,
    pub objects: usize,
    pub omitted: Vec<OmittedValues>,
    pub skipped: Vec<DumpSkip>,
    /// Tables whose foreign keys point at each other, written in the
    /// order they were listed.
    pub unordered: Vec<TableRef>,
}

#[derive(Debug, Clone, PartialEq, Error)]
pub enum DumpError {
    #[error(transparent)]
    Driver(#[from] DriverError),
    #[error("a table's read could not be built: {0}")]
    Read(#[from] BrowseSqlError),
    #[error("the file stopped taking bytes")]
    OutputClosed,
}

impl DumpError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::Driver(error) => error.code(),
            Self::Read(_) => "dump.read",
            Self::OutputClosed => "dump.output_closed",
        }
    }
}

impl From<DumpOutputClosed> for DumpError {
    fn from(_: DumpOutputClosed) -> Self {
        Self::OutputClosed
    }
}

/// Write `request`'s scope as one SQL file into `output`: the catalog in
/// the order a restore needs it, and each table's rows as INSERTs read
/// with `stream_read`. Tables are read one after another, each in a
/// transaction of its own, not at one snapshot.
pub async fn write_dump(
    connection: &dyn Connection,
    request: &DumpRequest,
    output: &mut dyn DumpOutput,
    options: CallOptions,
) -> Result<DumpReport, DumpError> {
    let dialect = connection.dialect();
    if dialect.dump().is_none() {
        return Err(DriverError::Unsupported {
            feature: UnsupportedFeature::SqlDump,
        }
        .into());
    }
    let catalog = connection.read_dump_catalog(&request.scope, options.clone()).await?;
    let mut writer = Writer {
        dialect: Arc::clone(&dialect),
        output,
        report: DumpReport {
            tables: catalog.tables.len(),
            skipped: catalog.skipped.clone(),
            ..DumpReport::default()
        },
        tables_done: 0,
        tables_read: catalog.tables.iter().filter(|table| table.rows).count(),
        data: request.data,
    };
    writer.run(connection, &catalog, request.data, options).await?;
    Ok(writer.report)
}

struct Writer<'a> {
    dialect: Arc<dyn SqlDialect>,
    output: &'a mut dyn DumpOutput,
    report: DumpReport,
    tables_done: usize,
    /// The tables whose rows are read, which progress counts.
    tables_read: usize,
    data: bool,
}

impl Writer<'_> {
    fn dump(&self) -> &dyn DumpDialect {
        self.dialect.dump().unwrap_or(&NO_DUMP)
    }

    async fn run(
        &mut self,
        connection: &dyn Connection,
        catalog: &DumpCatalog,
        data: bool,
        options: CallOptions,
    ) -> Result<(), DumpError> {
        let (table_order, unordered) = order_tables(&catalog.tables);
        self.report.unordered = unordered;
        let tables: Vec<&DumpTable> = table_order.iter().map(|&position| &catalog.tables[position]).collect();

        let mut head = preamble(connection.server_info());
        head.push_str(&self.dump().header());
        self.output.write(head.into_bytes()).await?;

        let section = |wanted: DumpSection| catalog.objects.iter().filter(move |object| object.section == wanted);
        let mut before: Vec<&DumpObject> = section(DumpSection::BeforeData)
            .filter(|object| object.table.is_none())
            .collect();
        before.extend(tables_in_order(&catalog.objects, &tables));
        let programs: Vec<&DumpObject> = section(DumpSection::Programs).collect();
        let after: Vec<&DumpObject> = section(DumpSection::AfterData).collect();
        let (early, late) = creation_order(&before, &programs, &after, self.dialect.grammar());
        self.objects(&early, &options).await?;

        if data {
            for table in tables.iter().filter(|table| table.rows) {
                options.cancel().cancelled_check()?;
                self.rows(connection, table, &options).await?;
                self.tables_done += 1;
                self.output.progress(self.progress());
            }
        }

        self.objects(&after, &options).await?;
        self.objects(&late, &options).await?;
        let triggers: Vec<&DumpObject> = section(DumpSection::Triggers).collect();
        self.objects(&triggers, &options).await?;

        let mut tail = self.dump().footer();
        tail.push_str("\n-- Dump completed\n");
        self.output.write(tail.into_bytes()).await?;
        Ok(())
    }

    fn progress(&self) -> DumpProgress {
        DumpProgress {
            tables_done: self.tables_done,
            tables_total: self.tables_read,
            rows: self.report.rows,
        }
    }

    async fn objects(&mut self, objects: &[&DumpObject], options: &CallOptions) -> Result<(), DumpError> {
        let mut text = String::new();
        for object in objects.iter().filter(|object| !object.statements.is_empty()) {
            options.cancel().cancelled_check()?;
            text.push_str(&self.dump().comment(&format!(
                "{}: {}",
                object.kind.label(),
                comment_safe(&qualified(object.schema.as_deref(), &object.name))
            )));
            let statements = match (&object.without_rows, self.data) {
                (Some(without_rows), false) => without_rows,
                _ => &object.statements,
            };
            for statement in statements {
                text.push_str(&self.dump().statement(&terminated_off(statement)));
            }
            self.report.objects += 1;
            if text.len() >= CHUNK_BYTES {
                self.output.write(std::mem::take(&mut text).into_bytes()).await?;
            }
        }
        if !text.is_empty() {
            self.output.write(text.into_bytes()).await?;
        }
        Ok(())
    }

    async fn rows(
        &mut self,
        connection: &dyn Connection,
        table: &DumpTable,
        options: &CallOptions,
    ) -> Result<(), DumpError> {
        let mut columns = connection.fetch_columns(&table.table, options.clone()).await?;
        for column in &mut columns {
            if table.plain_columns.contains(&column.name) {
                column.is_generated = false;
            }
        }
        // PostgreSQL allows a table of no columns, which no SELECT list
        // can read and whose rows only DEFAULT VALUES can write.
        if columns.is_empty() {
            self.report.skipped.push(DumpSkip {
                kind: DumpObjectKind::Table,
                schema: table.table.schema.clone(),
                name: table.table.name.clone(),
                reason: DumpSkipReason::RowsNotCarried,
            });
            return Ok(());
        }
        let columns: Arc<[ColumnInfo]> = columns.into();
        let identity = connection.row_identity(&table.table, options.clone()).await?;
        let read = build_export(
            &*self.dialect,
            &ExportRequest {
                table: &table.table,
                columns: &columns,
                filter: &FilterSet::default(),
                sort: &[],
                identity: &identity,
                fields: ExportFields::Listed,
            },
        )?;
        let written_as = match self.dialect.database_layout() {
            DatabaseLayout::AsSchemas => TableRef::unqualified(table.table.name.clone()),
            DatabaseLayout::Single | DatabaseLayout::WithSchemas => table.table.clone(),
        };
        let (sender, mut received) = mpsc::channel(CHUNKS_IN_FLIGHT);
        let sink = RowsSink {
            dialect: Arc::clone(&self.dialect),
            table_sql: self.dialect.portable_name(&written_as),
            info: Arc::clone(&columns),
            one_row_per_insert: table.one_row_per_insert,
            sender,
            batch: None,
            columns: Arc::from([]),
            rows: 0,
        };
        let sink = Box::new(DeclaredPrecisionSink::new(Box::new(sink), Arc::clone(&columns)));
        let header = self.dump().comment(&format!(
            "Data: {}",
            comment_safe(&qualified(table.table.schema.as_deref(), &table.table.name))
        ));
        self.output.write(header.into_bytes()).await?;

        let read = ReadStatement::Generated(read);
        let read = connection.stream_read(&read, sink, options.clone());
        let tables_total = self.tables_read;
        let rows_before = self.report.rows;
        let tables_done = self.tables_done;
        let output = &mut *self.output;
        let drain = async move {
            let mut omitted = Vec::new();
            let mut closed = false;
            while let Some(message) = received.recv().await {
                match message {
                    RowsMessage::Chunk { text, rows } => {
                        if output.write(text.into_bytes()).await.is_err() {
                            closed = true;
                            break;
                        }
                        output.progress(DumpProgress {
                            tables_done,
                            tables_total,
                            rows: rows_before + rows,
                        });
                    }
                    RowsMessage::Finished { rows, omitted: columns } => {
                        omitted = columns;
                        return (closed, rows, omitted);
                    }
                }
            }
            (closed, 0, omitted)
        };
        let (read, (closed, rows, omitted)) = futures::future::join(read, drain).await;
        if closed {
            return Err(DumpError::OutputClosed);
        }
        read?;
        self.report.rows += rows;
        self.report
            .omitted
            .extend(omitted.into_iter().map(|(column, count)| OmittedValues {
                table: table.table.clone(),
                column,
                count,
            }));
        Ok(())
    }
}

/// The CREATE TABLE objects in the order the tables load, then any for a
/// table the catalog lists no rows for.
fn tables_in_order<'a>(objects: &'a [DumpObject], tables: &[&DumpTable]) -> Vec<&'a DumpObject> {
    let creates: Vec<&DumpObject> = objects
        .iter()
        .filter(|object| object.section == DumpSection::BeforeData && object.table.is_some())
        .collect();
    let mut ordered: Vec<&DumpObject> = Vec::with_capacity(creates.len());
    for table in tables {
        ordered.extend(
            creates
                .iter()
                .filter(|object| object.table.as_ref() == Some(&table.table))
                .copied(),
        );
    }
    let listed = |object: &&DumpObject| tables.iter().any(|table| object.table.as_ref() == Some(&table.table));
    ordered.extend(creates.iter().filter(|object| !listed(object)).copied());
    ordered
}

/// A statement without the `;` the server's own text may end with, which
/// the dialect adds back in its own form. A routine body keeps its text.
fn terminated_off(statement: &DumpStatement) -> DumpStatement {
    let sql = statement.sql.trim_end();
    let sql = match statement.body {
        true => sql,
        false => sql.trim_end_matches(';').trim_end(),
    };
    DumpStatement {
        sql: sql.to_owned(),
        body: statement.body,
    }
}

fn qualified(schema: Option<&str>, name: &str) -> String {
    match schema {
        Some(schema) if !schema.is_empty() => format!("{schema}.{name}"),
        _ => name.to_owned(),
    }
}

/// A name in a `--` comment, with nothing that would end the comment and
/// make the rest of the name SQL, or a client command, on a line of its
/// own.
fn comment_safe(text: &str) -> String {
    text.chars()
        .map(|character| match character.is_control() {
            true => ' ',
            false => character,
        })
        .collect()
}

fn preamble(server: &crate::server_info::ServerInfo) -> String {
    format!(
        "-- TablePro SQL dump\n-- Server: {}\n",
        comment_safe(&format!("{} {}", server.product, server.version))
    )
}

#[derive(Debug)]
struct NoDump;
impl DumpDialect for NoDump {}
static NO_DUMP: NoDump = NoDump;

trait CancelCheck {
    fn cancelled_check(&self) -> Result<(), DumpError>;
}

impl CancelCheck for tokio_util::sync::CancellationToken {
    fn cancelled_check(&self) -> Result<(), DumpError> {
        match self.is_cancelled() {
            true => Err(DriverError::Cancelled.into()),
            false => Ok(()),
        }
    }
}

enum RowsMessage {
    Chunk { text: String, rows: u64 },
    Finished { rows: u64, omitted: Vec<(String, u64)> },
}

/// A table's rows as INSERT text, handed to the file a chunk at a time.
struct RowsSink {
    dialect: Arc<dyn SqlDialect>,
    table_sql: String,
    info: Arc<[ColumnInfo]>,
    one_row_per_insert: bool,
    sender: mpsc::Sender<RowsMessage>,
    batch: Option<InsertBatch>,
    columns: Arc<[ResultColumn]>,
    rows: u64,
}

impl RowsSink {
    fn text(&self, statements: Vec<DumpStatement>) -> String {
        let dump = self.dialect.dump().unwrap_or(&NO_DUMP);
        statements.iter().map(|statement| dump.statement(statement)).collect()
    }

    async fn send(&mut self, statements: Vec<DumpStatement>) -> SinkFlow {
        if statements.is_empty() {
            return SinkFlow::Continue;
        }
        let text = self.text(statements);
        let message = RowsMessage::Chunk { text, rows: self.rows };
        match self.sender.send(message).await {
            Ok(()) => SinkFlow::Continue,
            Err(_) => SinkFlow::ConsumerGone,
        }
    }

    fn encode(&mut self, rows: &[Vec<Value>]) -> Vec<DumpStatement> {
        let mut out = Vec::new();
        let dump = self.dialect.dump().unwrap_or(&NO_DUMP);
        if let Some(batch) = &mut self.batch {
            for row in rows {
                batch.row(&*self.dialect, dump, &self.columns, row, &mut out);
            }
        }
        self.rows += rows.len() as u64;
        out
    }
}

#[async_trait]
impl ResultSink for RowsSink {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        match event {
            ResultEvent::ResultSetStarted { columns } | ResultEvent::ColumnsResolved { columns, .. } => {
                if self.batch.is_none() {
                    self.batch = InsertBatch::new(
                        &*self.dialect,
                        self.table_sql.clone(),
                        &columns,
                        &self.info,
                        self.one_row_per_insert,
                    );
                }
                self.columns = columns;
                SinkFlow::Continue
            }
            ResultEvent::Rows(rows) => {
                let statements = self.encode(&rows);
                self.send(statements).await
            }
            ResultEvent::ResultSetFinished { .. } => {
                let mut out = Vec::new();
                let dump = self.dialect.dump().unwrap_or(&NO_DUMP);
                if let Some(batch) = &mut self.batch {
                    batch.finish(dump, &mut out);
                }
                let flow = self.send(out).await;
                let omitted = match &self.batch {
                    Some(batch) => batch
                        .omitted(&self.columns)
                        .map(|(column, count)| (column.to_owned(), count))
                        .collect(),
                    // Rows with no column to name and no DEFAULT VALUES
                    // spelling go in as nothing, which the report says.
                    None if self.rows > 0 => vec![("*".to_owned(), self.rows)],
                    None => Vec::new(),
                };
                let finished = RowsMessage::Finished {
                    rows: self.rows,
                    omitted,
                };
                match (flow, self.sender.send(finished).await) {
                    (SinkFlow::Continue, Ok(())) => SinkFlow::Continue,
                    _ => SinkFlow::ConsumerGone,
                }
            }
            ResultEvent::RowLimitReached { .. }
            | ResultEvent::ByteLimitReached { .. }
            | ResultEvent::CommandCompleted { .. }
            | ResultEvent::Notice(_)
            | ResultEvent::NoticeLimitReached { .. } => SinkFlow::Continue,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_name_with_a_line_break_stays_inside_its_comment() {
        let line = format!("\n-- Table: {}\n", comment_safe("t\nDROP TABLE users;\r\\! rm"));

        assert_eq!(line.lines().filter(|line| !line.is_empty()).count(), 1, "{line}");
    }

    #[test]
    fn the_servers_own_terminator_comes_off_a_statement_but_not_a_body() {
        assert_eq!(
            terminated_off(&DumpStatement::new("CREATE VIEW v AS SELECT 1;  \n")).sql,
            "CREATE VIEW v AS SELECT 1"
        );
        assert_eq!(
            terminated_off(&DumpStatement::body("BEGIN SELECT 1; END;")).sql,
            "BEGIN SELECT 1; END;"
        );
    }
}
