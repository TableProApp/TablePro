use crate::ColumnInfo;
use crate::import::cell::{ColumnKind, column_kind};

pub(crate) fn column_kind_for(column: &ColumnInfo, driver_id: &str) -> ColumnKind {
    if column.enum_type.is_some() || column.domain_type.is_some() {
        return ColumnKind::Text;
    }
    let lowered = column.data_type.trim().to_ascii_lowercase();
    let is_range = lowered.ends_with("range") || lowered.contains("multirange");
    let is_bit_string = driver_id == "postgres" && lowered.starts_with("bit");
    if is_range || is_bit_string {
        return ColumnKind::Text;
    }
    if driver_id == "mysql" && (lowered == "timestamp" || lowered.starts_with("timestamp(")) {
        return ColumnKind::TimestampTz;
    }
    column_kind(&column.data_type)
}
