//! LIST, ARRAY, STRUCT, MAP and UNION values as DuckDB's own text.

use duckdb::arrow::array::{Array, AsArray};

use super::text::{escaped, scalar_text};
use crate::duck_type::DuckType;

/// The value at `row` as DuckDB prints it, or `None` where a part of it
/// cannot be read off Arrow.
pub(super) fn text(array: &dyn Array, duck: &DuckType, row: usize) -> Option<String> {
    match duck {
        DuckType::List(element) => list(array, element, row),
        DuckType::Array(element, _) => {
            let values = array.as_fixed_size_list_opt()?;
            let width = usize::try_from(values.value_length()).ok()?;
            let start = values.value_offset_at(row);
            items(values.values().as_ref(), element, start..start + width)
        }
        DuckType::Struct(fields) => {
            let values = array.as_struct_opt()?;
            let mut parts = Vec::with_capacity(fields.len());
            for (index, (name, field)) in fields.iter().enumerate() {
                let column = values.columns().get(index)?;
                parts.push(format!(
                    "{}: {}",
                    escaped(name, true),
                    part(column.as_ref(), field, row)?
                ));
            }
            Some(format!("{{{}}}", parts.join(", ")))
        }
        DuckType::Map(key, value) => {
            let values = array.as_map_opt()?;
            let offsets = values.value_offsets();
            let (start, end) = (
                usize::try_from(*offsets.get(row)?).ok()?,
                usize::try_from(*offsets.get(row + 1)?).ok()?,
            );
            let mut parts = Vec::with_capacity(end - start);
            for entry in start..end {
                parts.push(format!(
                    "{}={}",
                    part(values.keys().as_ref(), key, entry)?,
                    part(values.values().as_ref(), value, entry)?
                ));
            }
            Some(format!("{{{}}}", parts.join(", ")))
        }
        DuckType::Union(members) => {
            let values = array.as_union_opt()?;
            let tag = values.type_id(row);
            let (_, member) = members.get(usize::try_from(tag).ok()?)?;
            let child = values.child(tag);
            let at = values.value_offset(row);
            match child.is_null(at) || matches!(member, DuckType::Null) {
                true => Some("NULL".to_owned()),
                false => whole(child.as_ref(), member, at),
            }
        }
        scalar => scalar_text(array, scalar, row),
    }
}

fn list(array: &dyn Array, element: &DuckType, row: usize) -> Option<String> {
    if let Some(values) = array.as_list_opt::<i32>() {
        let offsets = values.value_offsets();
        let range = usize::try_from(*offsets.get(row)?).ok()?..usize::try_from(*offsets.get(row + 1)?).ok()?;
        return items(values.values().as_ref(), element, range);
    }
    let values = array.as_list_opt::<i64>()?;
    let offsets = values.value_offsets();
    let range = usize::try_from(*offsets.get(row)?).ok()?..usize::try_from(*offsets.get(row + 1)?).ok()?;
    items(values.values().as_ref(), element, range)
}

fn items(values: &dyn Array, element: &DuckType, range: std::ops::Range<usize>) -> Option<String> {
    let parts: Option<Vec<String>> = range.map(|index| part(values, element, index)).collect();
    Some(format!("[{}]", parts?.join(", ")))
}

/// One member of a nested value: NULL, a nested value as it prints, or
/// a scalar escaped as DuckDB escapes one there.
fn part(values: &dyn Array, duck: &DuckType, row: usize) -> Option<String> {
    // A NULL-typed member, which DuckDB 2.0 gives an untyped NULL, is an
    // Arrow NullArray, and that reports no nulls through is_null.
    if values.is_null(row) || matches!(duck, DuckType::Null) {
        return Some("NULL".to_owned());
    }
    match duck.is_nested() {
        true => text(values, duck, row),
        false => Some(escaped(&scalar_text(values, duck, row)?, false)),
    }
}

/// A union prints its member's own text, unescaped.
fn whole(values: &dyn Array, duck: &DuckType, row: usize) -> Option<String> {
    match duck.is_nested() {
        true => text(values, duck, row),
        false => scalar_text(values, duck, row),
    }
}
