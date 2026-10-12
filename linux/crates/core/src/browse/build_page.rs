use crate::column::ColumnInfo;
use crate::dialect::{BindTarget, KeysetDirection, SqlDialect};
use crate::dml::{BuildSqlError, KeyComponent};
use crate::filter::build_filter;
use crate::meta::{EngineRowIdPart, PageCost, PagePosition, PageStability, RowIdentity};
use crate::statement::StatementBuilder;
use crate::value::Value;

use super::select_parts::{
    direction, identity_components, identity_order, projection_list, user_order, where_clause, with_tiebreak,
};
use super::{BrowseSqlError, PageLayout, PageRequest, PageSpec, PagingMode, RowKeyLayout, paging_mode};

/// The query for one page of a table.
///
/// The visible columns come first, through the dialect's projections,
/// and any engine row id parts follow as hidden columns that
/// `split_page` strips. The position decides how the page is found:
/// past a key, inside a block window, or at an offset, under the one
/// mode `paging_mode` picks for the table and sort.
pub fn build_page(dialect: &dyn SqlDialect, request: &PageRequest<'_>) -> Result<PageSpec, BrowseSqlError> {
    let mode = paging_mode(request.identity, request.sort);
    let components = identity_components(request.identity, request.columns)?;
    let (row_key, hidden) = row_key_layout(dialect, request.identity, request.columns, &components)?;
    let layout = PageLayout::new(request.columns.len(), hidden.as_ref().map_or(0, |(count, _)| *count));

    let mut projection = projection_list(dialect, request.columns)?;
    if let Some((_, hidden_sql)) = hidden {
        projection = format!("{projection}, {hidden_sql}");
    }

    let mut builder = StatementBuilder::new();
    let mut conditions = Vec::new();
    if build_filter(&mut builder, dialect, request.columns, request.filter)? {
        conditions.push(builder.take_fragment());
    }

    let identity_sql = identity_order(dialect, request.table, &components)?;
    let user = user_order(dialect, request.table, request.columns, request.sort)?;
    let walk = match mode {
        PagingMode::Keyset => keyset_walk(&mut builder, dialect, request, &components, &identity_sql)?,
        PagingMode::CtidWindow => ctid_walk(&mut builder, dialect, request.position)?,
        PagingMode::Offset => offset_walk(request.position, request.identity, with_tiebreak(user, &identity_sql))?,
    };
    conditions.extend(walk.condition);

    let order_by = (!walk.order.is_empty()).then(|| walk.order.join(", "));
    builder.push_sql(&format!(
        "SELECT {projection} FROM {}{}{}",
        dialect.qualify(request.table),
        where_clause(&conditions),
        dialect.row_window(order_by.as_deref(), request.limit, walk.offset)
    ));

    Ok(PageSpec {
        statement: builder.finish(),
        layout,
        row_key,
        stability: walk.stability,
        cost: walk.cost,
    })
}

/// How the page is located within the table.
struct Walk {
    condition: Option<String>,
    order: Vec<String>,
    offset: u64,
    stability: PageStability,
    cost: PageCost,
}

/// Where each row's key is read from, and the hidden projection with
/// its column count when the key is the engine's own row address.
fn row_key_layout(
    dialect: &dyn SqlDialect,
    identity: &RowIdentity,
    columns: &[ColumnInfo],
    components: &[KeyComponent<'_>],
) -> Result<(RowKeyLayout, Option<(usize, String)>), BrowseSqlError> {
    match identity {
        RowIdentity::Unordered => Ok((RowKeyLayout::ReadOnly, None)),
        RowIdentity::EngineRowId(id) => {
            let hidden = dialect.engine_row_id(*id).ok_or(BuildSqlError::NoRowIdentity)?;
            let parts = id.parts();
            Ok((
                RowKeyLayout::EngineRowId {
                    first_hidden: columns.len(),
                    parts,
                },
                Some((parts.len(), hidden)),
            ))
        }
        RowIdentity::UniqueKey { .. } | RowIdentity::SortingKey { .. } => {
            let positions = components
                .iter()
                .filter_map(|component| match component {
                    KeyComponent::Column(key) => columns.iter().position(|column| column.name == key.name),
                    KeyComponent::EngineRowId(_) => None,
                })
                .collect();
            Ok((RowKeyLayout::Columns(positions), None))
        }
    }
}

fn keyset_walk(
    builder: &mut StatementBuilder,
    dialect: &dyn SqlDialect,
    request: &PageRequest<'_>,
    components: &[KeyComponent<'_>],
    identity_sql: &[String],
) -> Result<Walk, BrowseSqlError> {
    let key_order = |keyset_direction: KeysetDirection| {
        let ascending = !keyset_direction.reverses_order();
        identity_sql
            .iter()
            .map(|expression| format!("{expression} {}", direction(ascending)))
            .collect::<Vec<_>>()
    };
    let (anchor, keyset_direction) = match request.position {
        PagePosition::First => (None, KeysetDirection::After),
        PagePosition::Offset(offset) => {
            return Ok(Walk {
                condition: None,
                order: key_order(KeysetDirection::After),
                offset: *offset,
                stability: PageStability::Stable,
                cost: PageCost::SortPerPage,
            });
        }
        PagePosition::AfterKey(key) => (Some(key), KeysetDirection::After),
        PagePosition::BeforeKey(key) => (Some(key), KeysetDirection::Before),
        PagePosition::CtidWindow { .. } => {
            return Err(BrowseSqlError::UnsupportedPosition {
                mode: PagingMode::Keyset,
            });
        }
    };
    let condition = match anchor {
        Some(key) => {
            let markers = bind_anchor(builder, dialect, components, key)?;
            Some(dialect.row_value_after(identity_sql, &markers, keyset_direction))
        }
        None => None,
    };
    Ok(Walk {
        condition,
        order: key_order(keyset_direction),
        offset: 0,
        stability: PageStability::Stable,
        cost: PageCost::KeySeek,
    })
}

/// Bind the edge row's key, taken from `BrowsePage::keys`, one marker
/// per key part in key order.
fn bind_anchor(
    builder: &mut StatementBuilder,
    dialect: &dyn SqlDialect,
    components: &[KeyComponent<'_>],
    key: &[Value],
) -> Result<Vec<String>, BrowseSqlError> {
    if key.len() != components.len() {
        return Err(BuildSqlError::LengthMismatch {
            expected: components.len(),
            found: key.len(),
        }
        .into());
    }
    let mut markers = Vec::with_capacity(key.len());
    for (component, value) in components.iter().zip(key) {
        match value {
            Value::Undecodable(_) => return Err(BuildSqlError::UndecodableKey.into()),
            Value::Null => return Err(BrowseSqlError::NullAnchor),
            _ => {}
        }
        let target = match component {
            KeyComponent::Column(column) => BindTarget::Column(column),
            KeyComponent::EngineRowId(part) => BindTarget::EngineRowId(*part),
        };
        markers.push(builder.bind(dialect, value.clone(), target)?);
    }
    Ok(markers)
}

/// A range of heap blocks in ctid order. The bounds are bound as text
/// the dialect casts back to a row address.
fn ctid_walk(
    builder: &mut StatementBuilder,
    dialect: &dyn SqlDialect,
    position: &PagePosition,
) -> Result<Walk, BrowseSqlError> {
    let ctid = dialect
        .engine_row_id_column(EngineRowIdPart::PostgresCtid)
        .ok_or(BuildSqlError::NoRowIdentity)?;
    let order = vec![format!("{ctid} {}", direction(true))];
    let (after, end_block) = match position {
        PagePosition::First => (None, None),
        PagePosition::Offset(offset) => {
            return Ok(Walk {
                condition: None,
                order,
                offset: *offset,
                stability: PageStability::Stable,
                cost: PageCost::SortPerPage,
            });
        }
        PagePosition::CtidWindow { after, end_block } => (*after, Some(*end_block)),
        PagePosition::AfterKey(_) | PagePosition::BeforeKey(_) => {
            return Err(BrowseSqlError::UnsupportedPosition {
                mode: PagingMode::CtidWindow,
            });
        }
    };

    let target = BindTarget::EngineRowId(EngineRowIdPart::PostgresCtid);
    let mut bounds = Vec::new();
    if let Some((block, offset)) = after {
        let marker = builder.bind(dialect, Value::Text(format!("({block},{offset})")), target)?;
        bounds.push(format!("{ctid} > {marker}"));
    }
    // A block number past what a tid can hold means the window runs to
    // the end of the table.
    if let Some(end_block) = end_block.and_then(|end| u32::try_from(end).ok()) {
        let marker = builder.bind(dialect, Value::Text(format!("({end_block},0)")), target)?;
        bounds.push(format!("{ctid} < {marker}"));
    }
    Ok(Walk {
        condition: (!bounds.is_empty()).then(|| bounds.join(" AND ")),
        order,
        offset: 0,
        stability: PageStability::Stable,
        cost: match end_block {
            Some(_) => PageCost::BlockWindow,
            None => PageCost::SortPerPage,
        },
    })
}

fn offset_walk(position: &PagePosition, identity: &RowIdentity, order: Vec<String>) -> Result<Walk, BrowseSqlError> {
    let offset = match position {
        PagePosition::First => 0,
        PagePosition::Offset(offset) => *offset,
        PagePosition::AfterKey(_) | PagePosition::BeforeKey(_) | PagePosition::CtidWindow { .. } => {
            return Err(BrowseSqlError::UnsupportedPosition {
                mode: PagingMode::Offset,
            });
        }
    };
    let stability = match identity {
        RowIdentity::UniqueKey { .. } | RowIdentity::EngineRowId(_) => PageStability::Stable,
        RowIdentity::SortingKey { .. } => PageStability::NonUniqueOrder,
        RowIdentity::Unordered => PageStability::Unordered,
    };
    Ok(Walk {
        condition: None,
        order,
        offset,
        stability,
        cost: PageCost::SortPerPage,
    })
}
