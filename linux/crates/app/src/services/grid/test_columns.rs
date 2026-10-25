use tablepro_core::column::{ColumnDefault, ColumnKind, ColumnType, classify_type_name};
use tablepro_core::{ColumnInfo, Value};

use super::{GridColumn, GridRowId};
use crate::services::change_tracker::RowKey;

pub fn info(name: &str, data_type: &str) -> ColumnInfo {
    info_of_kind(name, classify_type_name(data_type))
}

pub fn info_of_kind(name: &str, kind: ColumnKind) -> ColumnInfo {
    ColumnInfo {
        name: name.to_owned(),
        column_type: ColumnType {
            kind,
            ..ColumnType::untyped_text("t")
        },
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        is_generated: false,
        partition_scoped: false,
        default: ColumnDefault::None,
        comment: None,
    }
}

pub fn grid(info: ColumnInfo) -> GridColumn {
    GridColumn {
        index: 0,
        name: info.name.clone(),
        column_type: info.column_type.clone(),
        catalog: Some(info),
        addressable: true,
    }
}

pub fn grid_of_kind(name: &str, kind: ColumnKind) -> GridColumn {
    grid(info_of_kind(name, kind))
}

pub fn result_only(name: &str, kind: ColumnKind) -> GridColumn {
    GridColumn {
        catalog: None,
        ..grid_of_kind(name, kind)
    }
}

pub fn persisted() -> GridRowId {
    GridRowId::Persisted(RowKey::from_pk_values(&[Value::Int(1)]).expect("a key"))
}
