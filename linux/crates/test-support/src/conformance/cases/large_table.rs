use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use tablepro_core::browse::{ExportRequest, PageRead, PageRequest, PagingMode, build_export, read_page};
use tablepro_core::export::{CsvEncoder, CsvOptions, RowEncoder};
use tablepro_core::meta::{PagePosition, RowIdentity, TableRef};
use tablepro_core::{
    ColumnInfo, Connection, FilterSet, ReadStatement, ResultEvent, ResultSink, SinkFlow, UserSql, Value, WriteKind,
};

use crate::conformance::resident_peak::ResidentPeak;
use crate::conformance::support::{
    CALL_DEADLINE, apply_within, connect, count, create_scratch_table, expect, no_deadline, unexpected, within,
    writable,
};
use crate::conformance::{ConformanceFailure, LargeTableEngine};
use crate::lock;

const CASE: &str = "a_million_row_table_pages_to_its_end_and_exports";

const ROWS: u64 = 1_000_000;

/// Wide enough that the table is about 100 MB, so holding every row or
/// the whole file at once shows up far past the memory bound.
const LABEL_WIDTH: usize = 100;

/// The browse tab's default page size.
const PAGE: u64 = 1_000;

/// What the export sink holds before it writes, as the app's does.
const CHUNK_BYTES: usize = 64 * 1024;

const FILL_DEADLINE: Duration = Duration::from_secs(120);

/// The case fills its table first, so it gets longer than `CASE_LIMIT`,
/// and still ends before the `ci` nextest profile kills the test at
/// five minutes.
pub const LARGE_TABLE_CASE_LIMIT: Duration = Duration::from_secs(240);

/// Every page from the first to the last, read one after another. The
/// time bounds sit several times over what the slowest engine takes.
const WALK_LIMIT: Duration = Duration::from_secs(90);

/// A page that takes longer than this is a frozen grid.
const PAGE_LIMIT: Duration = Duration::from_secs(2);

const EXPORT_LIMIT: Duration = Duration::from_secs(90);

/// How far the process's resident peak may rise while it pages or
/// exports. The table is about 100 MB of text and more once decoded,
/// so a walk or an export that held it whole would pass this many
/// times over.
const MEMORY_LIMIT: u64 = 64 * 1024 * 1024;

/// Pages at each end of the walk whose times are compared.
const SAMPLE_PAGES: usize = 100;

/// How much slower the last pages may be than the first ones, where a
/// page is read past a key: a seek costs the same at any depth, and an
/// offset read 990,000 rows in costs hundreds of times more.
const DEPTH_FACTOR: u32 = 4;
const DEPTH_SLACK: Duration = Duration::from_millis(10);

/// A 1,000,000-row table pages from its first page to its end, by the
/// browse tab's default page size and the way its pager moves on, and
/// its last page reads straight from the end. An export of the whole
/// table then streams it to a CSV file the way the app's export does.
/// Each walk stays inside its time bound, and neither raises the
/// process's resident peak by more than the memory bound.
pub async fn a_million_row_table_pages_to_its_end_and_exports<E: LargeTableEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let connection = connect(CASE, &engine, writable()).await?;
    let table = create_scratch_table(&engine, connection.as_ref(), "million").await?;
    let filled = Instant::now();
    let fill = engine.fill_scratch_table_sql(&table, ROWS, LABEL_WIDTH);
    apply_within(
        connection.as_ref(),
        &table,
        WriteKind::SchemaChanges,
        fill,
        FILL_DEADLINE,
    )
    .await?;
    let fill = filled.elapsed();
    let browsed = Browsed::read(connection.as_ref(), table).await?;
    let directory = tempfile::tempdir().map_err(ConformanceFailure::setup)?;

    // The first page and a small export load the code both walks run,
    // so the peak measures rows and buffers, not the binary paging in.
    let first = browsed.page(connection.as_ref(), &PagePosition::First, PAGE).await?;
    check_rows(&first, 0)?;
    let warm = ReadStatement::User(UserSql::new(engine.row_source_sql(PAGE)));
    export(connection.as_ref(), &warm, &directory.path().join("warm.csv")).await?;

    let counted = Instant::now();
    let total = count(connection.as_ref(), &browsed.table).await?;
    let count = counted.elapsed();
    expect(CASE, total == ROWS, || {
        format!("the table counted {total} rows, not {ROWS}")
    })?;

    let peak = ResidentPeak::start()?;
    let walk = walk_to_the_end(&browsed, connection.as_ref()).await?;
    let last_read = Instant::now();
    let last_page = browsed.last_page(connection.as_ref(), first.mode).await?;
    let last = last_read.elapsed();
    let paging_growth = peak.growth()?;
    check_rows(&last_page, ROWS - PAGE)?;
    expect(CASE, last_page.result.rows.len() as u64 == PAGE, || {
        format!("the last page held {} rows, not {PAGE}", last_page.result.rows.len())
    })?;

    let path = directory.path().join("export.csv");
    let exported = export_table(&browsed, connection.as_ref(), &path).await?;
    let measured = Measured {
        mode: first.mode,
        fill,
        count,
        walk,
        last,
        paging_growth,
        exported,
    };
    report(&measured);
    check_bounds(&measured)?;
    check_file(&path)?;

    connection.close().await?;
    Ok(())
}

struct Exported {
    tally: Tally,
    elapsed: Duration,
    growth: u64,
}

/// Export the table as the export dialog's Entire Table does: the
/// statement `build_export` writes, streamed with no deadline.
async fn export_table(
    browsed: &Browsed,
    connection: &dyn Connection,
    path: &Path,
) -> Result<Exported, ConformanceFailure> {
    let request = ExportRequest {
        table: &browsed.table,
        columns: &browsed.columns,
        filter: &browsed.filter,
        sort: &[],
        identity: &browsed.identity,
    };
    let read = ReadStatement::Generated(
        build_export(&*connection.dialect(), &request)
            .map_err(|error| unexpected(CASE, format!("no export statement for the table: {error}")))?,
    );
    let peak = ResidentPeak::start()?;
    let started = Instant::now();
    let tally = export(connection, &read, path).await?;
    Ok(Exported {
        elapsed: started.elapsed(),
        growth: peak.growth()?,
        tally,
    })
}

fn check_bounds(measured: &Measured) -> Result<(), ConformanceFailure> {
    let Measured {
        walk,
        last,
        exported,
        paging_growth,
        ..
    } = measured;
    expect(CASE, walk.elapsed <= WALK_LIMIT, || {
        format!("{} pages took {:?}, past {WALK_LIMIT:?}", walk.pages, walk.elapsed)
    })?;
    expect(CASE, walk.slowest <= PAGE_LIMIT && *last <= PAGE_LIMIT, || {
        format!(
            "the slowest page took {:?} and the last {last:?}, past {PAGE_LIMIT:?}",
            walk.slowest
        )
    })?;
    if measured.mode != PagingMode::Offset {
        expect(CASE, walk.deep <= walk.early * DEPTH_FACTOR + DEPTH_SLACK, || {
            format!(
                "the last {SAMPLE_PAGES} pages took {:?} each and the first {:?}, so a page got slower further in",
                walk.deep, walk.early
            )
        })?;
    }
    expect(CASE, *paging_growth <= MEMORY_LIMIT, || {
        format!("paging raised the resident peak by {}", mebibytes(*paging_growth))
    })?;
    expect(CASE, exported.tally.rows == ROWS, || {
        format!("the export wrote {} rows, not {ROWS}", exported.tally.rows)
    })?;
    expect(CASE, exported.elapsed <= EXPORT_LIMIT, || {
        format!("the export took {:?}, past {EXPORT_LIMIT:?}", exported.elapsed)
    })?;
    expect(CASE, exported.growth <= MEMORY_LIMIT, || {
        format!("the export raised the resident peak by {}", mebibytes(exported.growth))
    })
}

/// The table as the browse tab reads it: its columns and row identity
/// from the catalogue, no filter.
struct Browsed {
    table: TableRef,
    columns: Vec<ColumnInfo>,
    identity: RowIdentity,
    filter: FilterSet,
}

impl Browsed {
    async fn read(connection: &dyn Connection, table: TableRef) -> Result<Self, ConformanceFailure> {
        let columns = connection.fetch_columns(&table, within(CALL_DEADLINE)).await?;
        let identity = connection.row_identity(&table, within(CALL_DEADLINE)).await?;
        Ok(Self {
            table,
            columns,
            identity,
            filter: FilterSet::default(),
        })
    }

    async fn page(
        &self,
        connection: &dyn Connection,
        position: &PagePosition,
        limit: u64,
    ) -> Result<PageRead, ConformanceFailure> {
        let request = PageRequest {
            table: &self.table,
            columns: &self.columns,
            filter: &self.filter,
            sort: &[],
            identity: &self.identity,
            position,
            limit,
        };
        read_page::<Box<dyn std::error::Error + Send + Sync>>(connection, &request, &within(CALL_DEADLINE))
            .await
            .map_err(|error| unexpected(CASE, format!("the page at {position:?} failed: {error}")))
    }

    /// The last page as the pager reaches it once the count is in: read
    /// back from the end, or by offset where the table pages that way.
    async fn last_page(&self, connection: &dyn Connection, mode: PagingMode) -> Result<PageRead, ConformanceFailure> {
        let start = (ROWS - 1) / PAGE * PAGE;
        let position = match mode {
            PagingMode::Offset => PagePosition::Offset(start),
            PagingMode::Keyset | PagingMode::CtidWindow => PagePosition::Last,
        };
        self.page(connection, &position, ROWS - start).await
    }
}

#[derive(Debug)]
struct Walk {
    pages: u64,
    elapsed: Duration,
    slowest: Duration,
    /// The mean time of the first and of the last full pages.
    early: Duration,
    deep: Duration,
}

/// Page forward from the first page as the pager does: past the last
/// row's key where the page names one, by offset where it does not,
/// until a page comes back short.
async fn walk_to_the_end(browsed: &Browsed, connection: &dyn Connection) -> Result<Walk, ConformanceFailure> {
    let started = Instant::now();
    let mut full_pages: Vec<Duration> = Vec::new();
    let mut pages = 0;
    let mut start = 0;
    let mut position = PagePosition::First;
    loop {
        let read_at = Instant::now();
        let read = browsed.page(connection, &position, PAGE).await?;
        let took = read_at.elapsed();
        pages += 1;
        check_rows(&read, start)?;
        let rows = read.result.rows.len() as u64;
        start += rows;
        if rows < PAGE {
            expect(CASE, start == ROWS, || {
                format!("the pages ended after {start} rows, not {ROWS}")
            })?;
            let sample = SAMPLE_PAGES.min(full_pages.len());
            return Ok(Walk {
                pages,
                elapsed: started.elapsed(),
                slowest: full_pages.iter().copied().max().unwrap_or_default().max(took),
                early: mean(&full_pages[..sample]),
                deep: mean(&full_pages[full_pages.len() - sample..]),
            });
        }
        full_pages.push(took);
        position = read.next.unwrap_or(PagePosition::Offset(start));
    }
}

fn mean(times: &[Duration]) -> Duration {
    let count = u32::try_from(times.len()).unwrap_or(u32::MAX).max(1);
    times.iter().sum::<Duration>() / count
}

/// The page holds the rows after the first `before`, in order, each
/// with its label.
fn check_rows(read: &PageRead, before: u64) -> Result<(), ConformanceFailure> {
    for (index, row) in read.result.rows.iter().enumerate() {
        let id = before + index as u64 + 1;
        let fits = matches!(row.first(), Some(value) if id_of(value) == Some(id))
            && matches!(row.get(1), Some(Value::Text(text)) if *text == label(id));
        expect(CASE, fits, || {
            format!(
                "row {id} of the table read as {:?}",
                row.iter().take(2).collect::<Vec<_>>()
            )
        })?;
    }
    Ok(())
}

fn id_of(value: &Value) -> Option<u64> {
    match value {
        Value::Int(id) => u64::try_from(*id).ok(),
        Value::UInt(id) => Some(*id),
        _ => None,
    }
}

fn label(id: u64) -> String {
    format!("{id:0>LABEL_WIDTH$}")
}

/// The file holds the header, then every row in key order.
fn check_file(path: &Path) -> Result<(), ConformanceFailure> {
    let file = File::open(path).map_err(ConformanceFailure::setup)?;
    let mut lines = BufReader::new(file).lines();
    let mut next = || lines.next().transpose().map_err(ConformanceFailure::setup);
    let header = next()?;
    expect(CASE, header.as_deref() == Some("\"id\",\"label\""), || {
        format!("the export started with {header:?}")
    })?;
    for id in 1..=ROWS {
        let line = next()?;
        let expected = format!("\"{id}\",\"{}\"", label(id));
        expect(CASE, line.as_deref() == Some(expected.as_str()), || {
            format!("line {id} of the export was {line:?}")
        })?;
    }
    let after = next()?;
    expect(CASE, after.is_none(), || {
        format!("the export went on past its last row: {after:?}")
    })
}

#[derive(Debug, Clone, Default)]
struct Tally {
    rows: u64,
    bytes: u64,
    result_sets: u32,
    failure: Option<String>,
}

/// Stream `read` into a CSV file the way the app's export sink does:
/// encoded row by row, written in chunks.
async fn export(connection: &dyn Connection, read: &ReadStatement, path: &Path) -> Result<Tally, ConformanceFailure> {
    let file = File::create(path).map_err(ConformanceFailure::setup)?;
    let tally = Arc::new(Mutex::new(Tally::default()));
    let sink = CsvFileSink {
        file,
        encoder: None,
        buffer: Vec::with_capacity(CHUNK_BYTES),
        tally: tally.clone(),
    };
    let summary = connection.stream_read(read, Box::new(sink), no_deadline()).await?;
    let tally = lock(&tally).clone();
    if let Some(failure) = &tally.failure {
        return Err(ConformanceFailure::setup(format!("the export file: {failure}")));
    }
    expect(CASE, tally.result_sets == 1 && summary.rows == tally.rows, || {
        format!(
            "the export reported {} rows and wrote {} in {} result sets",
            summary.rows, tally.rows, tally.result_sets
        )
    })?;
    Ok(tally)
}

struct CsvFileSink {
    file: File,
    encoder: Option<CsvEncoder>,
    buffer: Vec<u8>,
    tally: Arc<Mutex<Tally>>,
}

impl CsvFileSink {
    fn flush(&mut self) -> SinkFlow {
        if let Err(error) = self.file.write_all(&self.buffer) {
            lock(&self.tally).failure = Some(error.to_string());
            return SinkFlow::ConsumerGone;
        }
        lock(&self.tally).bytes += self.buffer.len() as u64;
        self.buffer.clear();
        SinkFlow::Continue
    }

    fn rows(&mut self, rows: &[Vec<Value>]) -> SinkFlow {
        let Some(encoder) = self.encoder.as_mut() else {
            lock(&self.tally).failure = Some("rows arrived before their result set started".to_owned());
            return SinkFlow::ConsumerGone;
        };
        for row in rows {
            if let Err(error) = encoder.row(&mut self.buffer, &mut row.iter()) {
                lock(&self.tally).failure = Some(error.to_string());
                return SinkFlow::ConsumerGone;
            }
        }
        lock(&self.tally).rows += rows.len() as u64;
        if self.buffer.len() >= CHUNK_BYTES {
            return self.flush();
        }
        SinkFlow::Continue
    }
}

#[async_trait]
impl ResultSink for CsvFileSink {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        match event {
            ResultEvent::ResultSetStarted { columns } => {
                lock(&self.tally).result_sets += 1;
                let mut encoder = CsvEncoder::new(columns, CsvOptions::default());
                encoder.begin(&mut self.buffer);
                self.encoder = Some(encoder);
                SinkFlow::Continue
            }
            ResultEvent::Rows(rows) => self.rows(&rows),
            ResultEvent::ResultSetFinished { .. } => {
                if let Some(encoder) = self.encoder.as_mut() {
                    encoder.finish(&mut self.buffer);
                }
                self.flush()
            }
            _ => SinkFlow::Continue,
        }
    }
}

struct Measured {
    mode: PagingMode,
    fill: Duration,
    count: Duration,
    walk: Walk,
    last: Duration,
    paging_growth: u64,
    exported: Exported,
}

#[expect(
    clippy::print_stderr,
    reason = "the numbers are what the bounds are set from; nextest shows them for a passing run"
)]
fn report(measured: &Measured) {
    eprintln!(
        "{CASE}: filled {ROWS} rows in {:.1?}, counted them in {:.1?}; {} pages by {:?} in {:.1?}, the slowest {:.1?}, \
         the first {SAMPLE_PAGES} {:.1?} each and the last {:.1?}, the last page in {:.1?}, peak +{}; \
         exported {} bytes in {:.1?}, peak +{}",
        measured.fill,
        measured.count,
        measured.walk.pages,
        measured.mode,
        measured.walk.elapsed,
        measured.walk.slowest,
        measured.walk.early,
        measured.walk.deep,
        measured.last,
        mebibytes(measured.paging_growth),
        measured.exported.tally.bytes,
        measured.exported.elapsed,
        mebibytes(measured.exported.growth),
    );
}

fn mebibytes(bytes: u64) -> String {
    format!("{:.1} MiB", bytes as f64 / (1024.0 * 1024.0))
}
