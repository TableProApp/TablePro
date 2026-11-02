use std::fmt;

use serde::de::{DeserializeSeed, Deserializer, Error as _, IgnoredAny, SeqAccess, Visitor};
use tablepro_core::value::{UndecodableReason, UndecodedValue};
use tablepro_core::{DriverError, Value};

use crate::cell_seed::{CellPlan, CellSeed};

/// Which cells of a row a pass reads; the rest it skips.
#[derive(Debug, Clone, Copy)]
enum Selection<'a> {
    All,
    Except(&'a [usize]),
    Only(usize),
}

impl Selection<'_> {
    fn reads(self, index: usize) -> bool {
        match self {
            Self::All => true,
            Self::Except(skipped) => !skipped.contains(&index),
            Self::Only(only) => only == index,
        }
    }
}

/// Reads one `JSONCompactEachRow` line as a row, one cell per plan.
struct RowSeed<'p> {
    plans: &'p [CellPlan],
    selection: Selection<'p>,
}

impl<'de> DeserializeSeed<'de> for RowSeed<'_> {
    type Value = Vec<Value>;

    fn deserialize<D: Deserializer<'de>>(self, deserializer: D) -> Result<Vec<Value>, D::Error> {
        deserializer.deserialize_seq(self)
    }
}

impl<'de> Visitor<'de> for RowSeed<'_> {
    type Value = Vec<Value>;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "a row of {} cells", self.plans.len())
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Vec<Value>, A::Error> {
        let mut row = Vec::with_capacity(self.plans.len());
        for (index, plan) in self.plans.iter().enumerate() {
            let seed = CellSeed {
                plan: self.selection.reads(index).then_some(plan),
            };
            match seq.next_element_seed(seed)? {
                Some(value) => row.push(value),
                None => return Err(A::Error::invalid_length(index, &self)),
            }
        }
        if seq.next_element::<IgnoredAny>()?.is_some() {
            return Err(A::Error::invalid_length(self.plans.len() + 1, &self));
        }
        Ok(row)
    }
}

fn pass(line: &[u8], plans: &[CellPlan], selection: Selection<'_>) -> Result<Vec<Value>, serde_json::Error> {
    let mut deserializer = serde_json::Deserializer::from_slice(line);
    let row = RowSeed { plans, selection }.deserialize(&mut deserializer)?;
    deserializer.end()?;
    Ok(row)
}

/// One row of a result.
///
/// A raw JSON token must be UTF-8, so one bad string inside a Map or a
/// Dynamic would lose the whole row. When a line fails, it is read again
/// with those columns skipped, then once per such column on its own: a
/// column that still fails becomes undecodable, and the rest of the row
/// is kept.
pub(crate) fn decode_row(line: &[u8], plans: &[CellPlan]) -> Result<Vec<Value>, DriverError> {
    let first = match pass(line, plans, Selection::All) {
        Ok(row) => return Ok(row),
        Err(error) => error,
    };
    let raw: Vec<usize> = plans
        .iter()
        .enumerate()
        .filter(|(_, plan)| plan.uses_raw())
        .map(|(index, _)| index)
        .collect();
    if raw.is_empty() {
        return Err(unreadable(&first));
    }
    let mut row = pass(line, plans, Selection::Except(&raw)).map_err(|error| unreadable(&error))?;
    for &index in &raw {
        let cell = pass(line, plans, Selection::Only(index))
            .ok()
            .and_then(|alone| alone.into_iter().nth(index));
        let value = cell.unwrap_or_else(|| {
            Value::Undecodable(Box::new(UndecodedValue {
                type_name: plans[index].type_name(),
                reason: UndecodableReason::InvalidEncoding,
            }))
        });
        if let Some(slot) = row.get_mut(index) {
            *slot = value;
        }
    }
    Ok(row)
}

fn unreadable(error: &serde_json::Error) -> DriverError {
    DriverError::Protocol(format!("the server sent a row the driver could not read: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dynamic() -> CellPlan {
        CellPlan::Raw {
            type_name: "Dynamic".to_owned(),
        }
    }

    #[test]
    fn dynamic_column_retry_isolates_invalid_cell() {
        let plans = [CellPlan::Integer, dynamic(), CellPlan::Text];

        let row = decode_row(b"[1,\"\xff\",\"\xfeok\"]", &plans).expect("a row");

        assert_eq!(row[0], Value::Int(1));
        assert_eq!(
            row[1],
            Value::Undecodable(Box::new(UndecodedValue {
                type_name: "Dynamic".to_owned(),
                reason: UndecodableReason::InvalidEncoding,
            }))
        );
        assert_eq!(row[2], Value::Bytes(vec![0xfe, b'o', b'k']));
    }

    #[test]
    fn a_valid_raw_cell_survives_the_retry_of_another() {
        let plans = [dynamic(), dynamic()];

        let row = decode_row(b"[\"ok\",\"\xff\"]", &plans).expect("a row");

        assert!(matches!(&row[0], Value::Other(other) if other.text == "\"ok\""));
        assert!(matches!(&row[1], Value::Undecodable(_)));
    }

    #[test]
    fn a_row_of_the_wrong_width_is_a_protocol_error() {
        let plans = [CellPlan::Integer, CellPlan::Integer];

        assert!(matches!(decode_row(b"[1]", &plans), Err(DriverError::Protocol(_))));
        assert!(matches!(decode_row(b"[1,2,3]", &plans), Err(DriverError::Protocol(_))));
    }
}
