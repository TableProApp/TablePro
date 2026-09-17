use super::{ColumnDefault, ColumnType, ResultColumn};

/// Everything the catalogue says about a table column.
///
/// This is the authority for browse: what can be edited, what the
/// server fills in, and what a value means. A result column carries
/// only the part an arbitrary query can report.
#[derive(Debug, Clone, PartialEq)]
pub struct ColumnInfo {
    pub name: String,
    pub column_type: ColumnType,
    pub nullable: bool,
    pub primary_key: bool,
    /// The server assigns the value, so an insert leaves the column
    /// out of the user-facing form.
    pub is_auto_increment: bool,
    /// `GENERATED ALWAYS AS`. Read-only, and never written.
    pub is_generated: bool,
    pub default: ColumnDefault,
    /// What the schema says the column is for, where the engine stores
    /// such a thing. `None` on an engine that has no column comments,
    /// which is not the same as one left empty.
    pub comment: Option<String>,
}

impl ColumnInfo {
    pub fn result_column(&self) -> ResultColumn {
        ResultColumn::new(self.name.clone(), self.column_type.clone())
    }

    /// Whether the user may put a value in this column at all. A
    /// generated column is computed by the server.
    pub fn is_writable(&self) -> bool {
        !self.is_generated
    }

    /// Whether an insert may leave the column out and still get a row:
    /// the server has something to put there.
    pub fn is_optional_on_insert(&self) -> bool {
        self.nullable || self.is_auto_increment || !self.default.is_none()
    }
}

#[cfg(test)]
mod tests {
    use super::super::{ColumnKind, IntegerKind, ReadForm, SqlExpression, SqlTypeExpr};
    use super::*;
    use crate::column::CatalogType;

    fn column(name: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType::new(
                SqlTypeExpr::from_catalog_text("integer"),
                ColumnKind::Integer(IntegerKind::I32),
                CatalogType::Oid(23),
                false,
                ReadForm::Native,
            ),
            nullable: false,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    #[test]
    fn a_result_column_keeps_the_name_and_type() {
        let info = column("id");

        let result = info.result_column();

        assert_eq!(result.name, "id");
        assert_eq!(result.column_type, info.column_type);
    }

    #[test]
    fn a_generated_column_is_not_writable() {
        let mut info = column("total");
        info.is_generated = true;

        assert!(!info.is_writable());
        assert!(column("id").is_writable());
    }

    #[test]
    fn insert_may_omit_a_column_the_server_can_fill() {
        let required = column("name");
        assert!(!required.is_optional_on_insert());

        let mut nullable = column("note");
        nullable.nullable = true;
        assert!(nullable.is_optional_on_insert());

        let mut serial = column("id");
        serial.is_auto_increment = true;
        assert!(serial.is_optional_on_insert());

        let mut defaulted = column("created_at");
        defaulted.default = ColumnDefault::Expression(SqlExpression::from_catalog_text("now()"));
        assert!(defaulted.is_optional_on_insert());
    }
}
