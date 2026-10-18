use crate::call_options::CallOptions;
use crate::connection::Connection;
use crate::error::DriverError;
use crate::meta::{CtidWindow, EngineRowIdPart, HeapAddress, PagePosition, RowIdentity, TableEstimate};
use crate::query_result::QueryResult;
use crate::row_limit::RowLimit;
use crate::value::Value;

use super::split_page::key_of;
use super::{BrowseSqlError, PageLayout, PageRequest, PageSpec, PagingMode, RowKeyLayout, build_page, paging_mode};

/// Rows per heap block assumed for a table the server never analysed.
/// Low on purpose: a window too wide costs a little sorting, one too
/// narrow costs another round trip.
const ASSUMED_ROWS_PER_BLOCK: u64 = 16;

/// A page as the server returned it, its rows in the table's order.
#[derive(Debug, Clone)]
pub struct PageRead {
    /// The visible columns, then the row identity's.
    pub result: QueryResult,
    pub layout: PageLayout,
    /// What the rows are. A read backward that reached the start of the
    /// table before it filled the page is the first page.
    pub position: PagePosition,
    pub mode: PagingMode,
    /// The page before this one by its first row's key, and the page
    /// after it by its last. `None` where only an offset reaches it: the
    /// table pages by offset, or the edge row's key could not be read.
    pub previous: Option<PagePosition>,
    pub next: Option<PagePosition>,
}

/// Read the page `request` names, by the mode `paging_mode` picks.
///
/// A page of a keyless PostgreSQL table is read through block windows,
/// so no read sorts more of the table than a page's worth of blocks.
pub async fn read_page<E>(
    connection: &dyn Connection,
    request: &PageRequest<'_>,
    options: &CallOptions,
) -> Result<PageRead, E>
where
    E: From<BrowseSqlError> + From<DriverError>,
{
    let mode = paging_mode(request.identity, request.sort);
    let (mut result, mut spec) = read_at::<E>(connection, request, request.position, options).await?;
    let mut position = request.position.clone();
    let reached_start = reads_backward(request.position) && (result.rows.len() as u64) < request.limit;
    if reached_start {
        position = PagePosition::First;
        // Rows past the anchor fill the rest of the first page.
        if matches!(request.position, PagePosition::BeforeKey(_)) {
            (result, spec) = read_at::<E>(connection, request, &PagePosition::First, options).await?;
        }
    }
    let (previous, next) = match mode {
        PagingMode::Offset => (None, None),
        PagingMode::Keyset | PagingMode::CtidWindow => (
            edge_key(result.rows.first(), &spec.row_key).map(PagePosition::BeforeKey),
            edge_key(result.rows.last(), &spec.row_key).map(PagePosition::AfterKey),
        ),
    };
    Ok(PageRead {
        result,
        layout: spec.layout,
        position,
        mode,
        previous,
        next,
    })
}

fn reads_backward(position: &PagePosition) -> bool {
    match position {
        PagePosition::Last | PagePosition::BeforeKey(_) => true,
        PagePosition::CtidWindow(window) => window.backward,
        PagePosition::First | PagePosition::Offset(_) | PagePosition::AfterKey(_) => false,
    }
}

/// A key a later page can be read past: whole, readable and not null.
fn edge_key(row: Option<&Vec<Value>>, layout: &RowKeyLayout) -> Option<Vec<Value>> {
    key_of(row?, layout).filter(|key| key.iter().all(|value| !value.is_null()))
}

async fn read_at<E>(
    connection: &dyn Connection,
    request: &PageRequest<'_>,
    position: &PagePosition,
    options: &CallOptions,
) -> Result<(QueryResult, PageSpec), E>
where
    E: From<BrowseSqlError> + From<DriverError>,
{
    let start = match paging_mode(request.identity, request.sort) {
        PagingMode::CtidWindow => ctid_start(position, request.identity)?,
        PagingMode::Keyset | PagingMode::Offset => None,
    };
    let (mut result, spec) = match start {
        Some(start) => walk_heap::<E>(connection, request, start, options).await?,
        None => query::<E>(connection, request, position, request.limit, options).await?,
    };
    if reads_backward(position) {
        result.rows.reverse();
    }
    Ok((result, spec))
}

/// Where a walk of the heap starts, for a position a single window
/// cannot answer.
fn ctid_start(position: &PagePosition, identity: &RowIdentity) -> Result<Option<CtidStart>, BrowseSqlError> {
    Ok(match position {
        PagePosition::First => Some(CtidStart::Forward(None)),
        PagePosition::Last => Some(CtidStart::Backward(None)),
        PagePosition::AfterKey(key) => Some(CtidStart::Forward(Some(heap_address(key, identity)?))),
        PagePosition::BeforeKey(key) => Some(CtidStart::Backward(Some(heap_address(key, identity)?))),
        PagePosition::Offset(_) | PagePosition::CtidWindow(_) => None,
    })
}

/// The ctid in a row's key, which a page projects as text: `(block,line)`.
fn heap_address(key: &[Value], identity: &RowIdentity) -> Result<HeapAddress, BrowseSqlError> {
    let RowIdentity::EngineRowId(id) = identity else {
        return Err(BrowseSqlError::UnreadableAnchor);
    };
    let text = id
        .parts()
        .iter()
        .position(|part| *part == EngineRowIdPart::PostgresCtid)
        .and_then(|index| key.get(index));
    match text {
        Some(Value::Text(text)) => parse_heap_address(text).ok_or(BrowseSqlError::UnreadableAnchor),
        _ => Err(BrowseSqlError::UnreadableAnchor),
    }
}

fn parse_heap_address(text: &str) -> Option<HeapAddress> {
    let (block, line) = text.strip_prefix('(')?.strip_suffix(')')?.split_once(',')?;
    Some((block.trim().parse().ok()?, line.trim().parse().ok()?))
}

async fn query<E>(
    connection: &dyn Connection,
    request: &PageRequest<'_>,
    position: &PagePosition,
    limit: u64,
    options: &CallOptions,
) -> Result<(QueryResult, PageSpec), E>
where
    E: From<BrowseSqlError> + From<DriverError>,
{
    let dialect = connection.dialect();
    let spec = build_page(
        &*dialect,
        &PageRequest {
            position,
            limit,
            ..*request
        },
    )?;
    let row_limit = RowLimit::new(limit).unwrap_or(RowLimit::EDITOR_DEFAULT);
    let result = connection
        .query_bound(&spec.statement, row_limit, options.clone())
        .await?;
    check_shape(&result, &spec.layout)?;
    Ok((result, spec))
}

/// Fill a page from block windows, each read in ctid order, until it
/// is full or the walk passes the end of the table. Rows come back in
/// the order the walk read them.
async fn walk_heap<E>(
    connection: &dyn Connection,
    request: &PageRequest<'_>,
    start: CtidStart,
    options: &CallOptions,
) -> Result<(QueryResult, PageSpec), E>
where
    E: From<BrowseSqlError> + From<DriverError>,
{
    let estimate = connection.table_estimate(request.table, options.clone()).await?;
    let mut walk = CtidWalk::new(start, &estimate, request.limit);
    let mut rows = Vec::new();
    loop {
        let wanted = request.limit.saturating_sub(rows.len() as u64).max(1);
        let position = PagePosition::CtidWindow(walk.window());
        let (result, spec) = query::<E>(connection, request, &position, wanted, options).await?;
        let filled = result.rows.len() as u64 >= wanted;
        rows.extend(result.rows);
        if filled || !walk.advance() {
            return Ok((QueryResult::new(result.columns, rows), spec));
        }
    }
}

/// Every row has the columns the page asked for, visible then identity,
/// so the split on the GTK thread takes each row apart at the same place.
fn check_shape(result: &QueryResult, layout: &PageLayout) -> Result<(), BrowseSqlError> {
    let expected = layout.width();
    let found = std::iter::once(result.columns.len())
        .chain(result.rows.iter().map(Vec::len))
        .find(|width| *width != expected);
    match found {
        Some(found) => Err(BrowseSqlError::ShapeMismatch { expected, found }),
        None => Ok(()),
    }
}

/// Which way a walk of the heap reads, and the row it reads past.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum CtidStart {
    Forward(Option<HeapAddress>),
    Backward(Option<HeapAddress>),
}

/// The block windows a page of a keyless PostgreSQL table is read
/// through. A window that comes back short is followed by one twice as
/// wide, so a sparse table or a narrow filter still takes few reads.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct CtidWalk {
    backward: bool,
    /// The row the next window reads past, or the start of a block.
    edge: Option<HeapAddress>,
    /// The next window's first block, or going backward the block just
    /// past its last.
    block: u64,
    span: u64,
    heap_blocks: u64,
}

impl CtidWalk {
    pub(super) fn new(start: CtidStart, estimate: &TableEstimate, limit: u64) -> Self {
        let heap_blocks = estimate.heap_blocks.unwrap_or(0);
        let rows_per_block = match estimate.rows.value() {
            Some(rows) if heap_blocks > 0 => (rows / heap_blocks).max(1),
            _ => ASSUMED_ROWS_PER_BLOCK,
        };
        let span = limit.div_ceil(rows_per_block).max(1);
        let (backward, edge, block) = match start {
            CtidStart::Forward(edge) => (false, edge, edge.map_or(0, |(block, _)| u64::from(block))),
            CtidStart::Backward(edge) => (true, edge, edge.map_or(heap_blocks, |(block, _)| u64::from(block) + 1)),
        };
        Self {
            backward,
            edge,
            block,
            span,
            heap_blocks,
        }
    }

    pub(super) fn window(&self) -> CtidWindow {
        match self.backward {
            false => CtidWindow {
                after: self.edge,
                before: self.forward_end().map(block_start),
                backward: false,
            },
            true => CtidWindow {
                after: self.backward_start().map(block_start),
                before: self.edge,
                backward: true,
            },
        }
    }

    /// Move on past a window that came back short. False when that
    /// window already ran to the end of the table.
    pub(super) fn advance(&mut self) -> bool {
        let next = match self.backward {
            false => self.forward_end(),
            true => self.backward_start(),
        };
        let Some(block) = next else {
            return false;
        };
        self.edge = Some(block_start(block));
        self.block = u64::from(block);
        self.span = self.span.saturating_mul(2);
        true
    }

    /// The block a forward window stops before. `None` lets the last
    /// window run on past the size read at the start, for rows added
    /// since.
    fn forward_end(&self) -> Option<u32> {
        let end = self.block.saturating_add(self.span);
        (end < self.heap_blocks).then(|| u32::try_from(end).ok()).flatten()
    }

    /// The first block of a backward window, `None` once it reaches the
    /// start of the table.
    fn backward_start(&self) -> Option<u32> {
        let start = self.block.saturating_sub(self.span);
        (start > 0).then(|| u32::try_from(start).ok()).flatten()
    }
}

fn block_start(block: u32) -> HeapAddress {
    (block, 0)
}

#[cfg(test)]
mod tests {
    use crate::meta::RowCountEstimate;

    use super::*;

    fn estimate(rows: u64, heap_blocks: u64) -> TableEstimate {
        TableEstimate {
            rows: RowCountEstimate::Approximate(rows),
            heap_blocks: Some(heap_blocks),
        }
    }

    fn windows(mut walk: CtidWalk) -> Vec<CtidWindow> {
        let mut windows = vec![walk.window()];
        while walk.advance() {
            windows.push(walk.window());
        }
        windows
    }

    fn forward(after: Option<HeapAddress>, before: Option<HeapAddress>) -> CtidWindow {
        CtidWindow {
            after,
            before,
            backward: false,
        }
    }

    fn backward(after: Option<HeapAddress>, before: Option<HeapAddress>) -> CtidWindow {
        CtidWindow {
            after,
            before,
            backward: true,
        }
    }

    #[test]
    fn a_window_holds_about_a_page_by_the_tables_own_density() {
        // 100 rows a block, so a page of 1,000 needs 10 blocks.
        let walk = CtidWalk::new(CtidStart::Forward(None), &estimate(100_000, 1_000), 1_000);

        assert_eq!(walk.window(), forward(None, Some((10, 0))));
    }

    #[test]
    fn a_short_window_is_followed_by_one_twice_as_wide_up_to_the_end() {
        let walk = CtidWalk::new(CtidStart::Forward(Some((5, 3))), &estimate(10_000, 100), 1_000);

        assert_eq!(
            windows(walk),
            [
                forward(Some((5, 3)), Some((15, 0))),
                forward(Some((15, 0)), Some((35, 0))),
                forward(Some((35, 0)), Some((75, 0))),
                forward(Some((75, 0)), None),
            ],
            "the last window must run past the size read, for rows added since"
        );
    }

    #[test]
    fn a_backward_walk_ends_at_the_first_block() {
        let walk = CtidWalk::new(CtidStart::Backward(Some((40, 2))), &estimate(10_000, 100), 1_000);

        assert_eq!(
            windows(walk),
            [
                backward(Some((31, 0)), Some((40, 2))),
                backward(Some((11, 0)), Some((31, 0))),
                backward(None, Some((11, 0))),
            ]
        );
    }

    #[test]
    fn the_last_page_starts_from_the_tables_end_with_no_upper_bound() {
        let walk = CtidWalk::new(CtidStart::Backward(None), &estimate(10_000, 100), 1_000);

        assert_eq!(walk.window(), backward(Some((90, 0)), None));
    }

    #[test]
    fn a_table_never_analysed_or_empty_still_walks() {
        let unknown = TableEstimate {
            rows: RowCountEstimate::Unknown,
            heap_blocks: Some(10_000),
        };
        let walk = CtidWalk::new(CtidStart::Forward(None), &unknown, 1_000);
        assert_eq!(walk.window(), forward(None, Some((63, 0))));

        let empty = CtidWalk::new(CtidStart::Forward(None), &estimate(0, 0), 1_000);
        assert_eq!(windows(empty), [forward(None, None)]);
    }

    #[test]
    fn a_heap_address_is_read_from_the_ctid_part_of_the_key() {
        let ctid = RowIdentity::EngineRowId(crate::meta::EngineRowId::PostgresCtid);
        let partitioned = RowIdentity::EngineRowId(crate::meta::EngineRowId::PostgresTableoidCtid);
        let key = |parts: &[&str]| -> Vec<Value> { parts.iter().map(|part| Value::Text((*part).to_owned())).collect() };

        assert_eq!(heap_address(&key(&["(4294967295,7)", "812"]), &ctid), Ok((u32::MAX, 7)));
        assert_eq!(heap_address(&key(&["16384", "(0,1)", "812"]), &partitioned), Ok((0, 1)));
        assert_eq!(
            heap_address(&key(&["(4,x)", "812"]), &ctid),
            Err(BrowseSqlError::UnreadableAnchor)
        );
        assert_eq!(
            heap_address(&[Value::Int(4)], &ctid),
            Err(BrowseSqlError::UnreadableAnchor)
        );
    }
}
