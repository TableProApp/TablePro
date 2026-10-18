use super::ColumnAttributes;
use crate::column::ColumnInfo;

/// A column as its table's DDL defines it.
#[derive(Debug, Clone, PartialEq)]
pub struct ColumnDefinition {
    pub info: ColumnInfo,
    pub attributes: ColumnAttributes,
}

impl ColumnDefinition {
    pub fn new(info: ColumnInfo, attributes: ColumnAttributes) -> Self {
        Self { info, attributes }
    }

    pub fn name(&self) -> &str {
        &self.info.name
    }
}
