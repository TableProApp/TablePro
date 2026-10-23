//! A page of CQL rows as the app holds a result.

use std::ops::ControlFlow;
use std::sync::Arc;

use scylla::response::query_result::{ColumnSpecs, QueryResult, QueryRowsResult};
use scylla::response::{PagingState, PagingStateResponse};
use scylla::value::{CqlValue, Row};
use tablepro_core::column::ResultColumn;
use tablepro_core::statement::Statement;
use tablepro_core::{DriverError, QueryResult as Rows, ServerPage, ServerPageRequest, StopRequest, Value};

use crate::call::stoppable;
use crate::cql_type::CqlType;
use crate::decode::decode;
use crate::session::CqlLink;

/// The most rows a page asks the server for. A larger page is one
/// response held whole in memory.
pub(crate) const MAX_PAGE_ROWS: u64 = 5_000;

/// What a result's metadata says about each column.
#[derive(Debug, Clone)]
pub(crate) struct ColumnsRead {
    pub(crate) columns: Arc<[ResultColumn]>,
    type_names: Vec<String>,
}

impl ColumnsRead {
    pub(crate) fn of(specs: ColumnSpecs<'_, '_>) -> Self {
        let mut columns = Vec::with_capacity(specs.len());
        let mut type_names = Vec::with_capacity(specs.len());
        for spec in specs.iter() {
            let cql_type = CqlType::from_wire(spec.typ());
            type_names.push(cql_type.to_string());
            columns.push(ResultColumn::new(spec.name(), cql_type.column_type(None)));
        }
        Self {
            columns: columns.into(),
            type_names,
        }
    }

    /// Every row of `rows`, each value read for its column's type.
    pub(crate) fn decode(&self, rows: &QueryRowsResult) -> Result<Vec<Vec<Value>>, DriverError> {
        let iter = rows
            .rows::<Row>()
            .map_err(|error| DriverError::Protocol(error.to_string()))?;
        let mut decoded = Vec::with_capacity(rows.rows_num());
        for row in iter {
            let row = row.map_err(|error| DriverError::Protocol(error.to_string()))?;
            decoded.push(
                row.columns
                    .into_iter()
                    .zip(&self.type_names)
                    .map(|(value, type_name)| decode(value, type_name))
                    .collect(),
            );
        }
        Ok(decoded)
    }
}

/// Whether a lightweight transaction took effect, from the `[applied]`
/// column the server puts first in its answer. `None` for a statement
/// that is not one.
pub(crate) fn applied(result: QueryResult) -> Result<Option<bool>, DriverError> {
    if !result.is_rows() {
        return Ok(None);
    }
    let rows = result
        .into_rows_result()
        .map_err(|error| DriverError::Protocol(error.to_string()))?;
    let is_lwt = rows
        .column_specs()
        .get_by_index(0)
        .is_some_and(|spec| spec.name() == "[applied]");
    if !is_lwt {
        return Ok(None);
    }
    let row = rows
        .maybe_first_row::<Row>()
        .map_err(|error| DriverError::Protocol(error.to_string()))?;
    Ok(Some(matches!(
        row.and_then(|row| row.columns.into_iter().next()).flatten(),
        Some(CqlValue::Boolean(true))
    )))
}

/// A page of a generated read, read past `skip` rows without decoding
/// them, and the paging state that resumes after its last row.
///
/// ScyllaDB answers a filtered page with fewer rows than asked, even
/// none, while more follow, so pages are read until the page is full or
/// the server says nothing follows. Each asks for no more than the page
/// still needs, so the last paging state sits right after the last row
/// kept.
pub(crate) async fn server_page(
    link: &CqlLink,
    statement: &Statement,
    request: ServerPageRequest,
    stop: &StopRequest,
) -> Result<ServerPage, DriverError> {
    let mut state = request
        .resume
        .map_or_else(PagingState::start, PagingState::new_from_raw_bytes);
    let mut skip = request.skip;
    let limit = request.limit.get();
    let mut kept: Vec<Vec<Value>> = Vec::new();
    let mut read: Option<ColumnsRead> = None;
    loop {
        let wanted = match skip {
            0 => (limit - kept.len() as u64).min(MAX_PAGE_ROWS),
            _ => skip.min(MAX_PAGE_ROWS),
        };
        let (result, response) = stoppable(stop, link.page(statement, page_size(wanted), state)).await?;
        let rows = result
            .into_rows_result()
            .map_err(|error| DriverError::Protocol(error.to_string()))?;
        let columns = read.get_or_insert_with(|| ColumnsRead::of(rows.column_specs()));
        if skip > 0 {
            skip -= (rows.rows_num() as u64).min(skip);
        } else {
            kept.extend(columns.decode(&rows)?);
        }
        let next = match next_state(response) {
            Some(next) => next,
            None => return Ok(finished(read, kept, None)),
        };
        if skip == 0 && kept.len() as u64 >= limit {
            return Ok(finished(read, kept, next.as_bytes_slice().cloned()));
        }
        state = next;
    }
}

pub(crate) fn next_state(response: PagingStateResponse) -> Option<PagingState> {
    match response.into_paging_control_flow() {
        ControlFlow::Continue(state) => Some(state),
        ControlFlow::Break(()) => None,
    }
}

pub(crate) fn page_size(rows: u64) -> i32 {
    i32::try_from(rows.max(1)).unwrap_or(i32::MAX)
}

fn finished(read: Option<ColumnsRead>, rows: Vec<Vec<Value>>, next: Option<Arc<[u8]>>) -> ServerPage {
    let columns = read.map_or_else(|| Arc::from([]), |read| read.columns);
    ServerPage {
        result: Rows::new(columns, rows),
        next,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_page_size_is_never_zero_and_never_overflows() {
        assert_eq!(page_size(0), 1);
        assert_eq!(page_size(5_000), 5_000);
        assert_eq!(page_size(u64::MAX), i32::MAX);
    }
}
