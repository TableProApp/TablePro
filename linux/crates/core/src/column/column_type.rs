use super::{ColumnKind, ReadForm, SqlTypeExpr};

/// A column's type: what the app needs to render and edit it, plus the
/// server's own spelling for round-tripping it into DDL.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ColumnType {
    /// What the user sees, which is the server's spelling.
    name: SqlTypeExpr,
    kind: ColumnKind,
    catalog: CatalogType,
    /// Whether the server decides the stored width per row, so a
    /// declared length is a cap rather than a promise.
    dynamic_storage: bool,
    read_form: ReadForm,
}

/// The engine's own identification of the type, which the driver needs
/// to bind a parameter back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CatalogType {
    /// No catalogue identifier: the type is known only by its name.
    Unknown,
    /// PostgreSQL pg_type.oid, and any engine that numbers its types.
    Oid(u32),
    /// A named catalogue entry, such as a MySQL column_type string or a
    /// ClickHouse type expression.
    Named(SqlTypeExpr),
}

impl ColumnType {
    pub fn new(
        name: SqlTypeExpr,
        kind: ColumnKind,
        catalog: CatalogType,
        dynamic_storage: bool,
        read_form: ReadForm,
    ) -> Self {
        Self {
            name,
            kind,
            catalog,
            dynamic_storage,
            read_form,
        }
    }

    /// A stand-in for a column whose type is not known yet, used
    /// while the catalogue is still loading.
    ///
    /// It names no server type, so nothing can paste it into DDL: a
    /// caller that needs the server's own spelling has to wait for the
    /// catalogue rather than invent one.
    pub fn unknown() -> Self {
        Self {
            name: SqlTypeExpr::from_catalog_text(""),
            kind: ColumnKind::Other,
            catalog: CatalogType::Unknown,
            dynamic_storage: true,
            read_form: ReadForm::ServerText,
        }
    }

    /// The fallback for a type no driver placed: the value is the
    /// server's text and the grid treats it as such.
    pub fn untyped_text(name: SqlTypeExpr) -> Self {
        Self {
            name,
            kind: ColumnKind::Other,
            catalog: CatalogType::Unknown,
            dynamic_storage: true,
            read_form: ReadForm::ServerText,
        }
    }

    pub fn name(&self) -> &SqlTypeExpr {
        &self.name
    }

    pub fn kind(&self) -> ColumnKind {
        self.kind
    }

    pub fn catalog(&self) -> &CatalogType {
        &self.catalog
    }

    pub fn dynamic_storage(&self) -> bool {
        self.dynamic_storage
    }

    pub fn read_form(&self) -> ReadForm {
        self.read_form
    }

    /// The fractional-second digits the column declares, as in
    /// `timestamp(6)`.
    ///
    /// `None` where the type names none, which is not the same as zero:
    /// a value's own fraction is then all anyone knows about it.
    pub fn fractional_digits(&self) -> Option<u32> {
        if !matches!(self.kind, ColumnKind::Time | ColumnKind::Timestamp) {
            return None;
        }
        type_arguments(self.name.as_sql()).first().copied()
    }

    /// The digits after the decimal point the column declares, as in
    /// `numeric(38,10)`.
    pub fn decimal_scale(&self) -> Option<u32> {
        if self.kind != ColumnKind::Decimal {
            return None;
        }
        let arguments = type_arguments(self.name.as_sql());
        match arguments.len() {
            // `numeric(10)` is `numeric(10,0)`.
            1 => Some(0),
            _ => arguments.get(1).copied(),
        }
    }
}

/// The numbers inside a type's parentheses, in order. A type with none,
/// or with anything that is not a number, has no arguments to read.
fn type_arguments(sql: &str) -> Vec<u32> {
    let Some(open) = sql.find('(') else {
        return Vec::new();
    };
    let Some(close) = sql[open..].find(')') else {
        return Vec::new();
    };
    sql[open + 1..open + close]
        .split(',')
        .map(|part| part.trim().parse::<u32>())
        .collect::<Result<Vec<u32>, _>>()
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unknown_type_names_nothing_the_server_would_recognise() {
        let unknown = ColumnType::unknown();

        assert_eq!(unknown.name().as_sql(), "");
        assert_eq!(unknown.kind(), ColumnKind::Other);
    }

    #[test]
    fn a_declared_precision_is_read_from_the_type_the_server_named() {
        let stamp = ColumnType::new(
            SqlTypeExpr::from_catalog_text("timestamp(6) with time zone"),
            ColumnKind::Timestamp,
            CatalogType::Unknown,
            false,
            ReadForm::Native,
        );

        assert_eq!(stamp.fractional_digits(), Some(6));
        assert_eq!(stamp.decimal_scale(), None, "a timestamp has no decimal scale");
    }

    #[test]
    fn a_type_with_no_parentheses_declares_no_precision() {
        let stamp = ColumnType::new(
            SqlTypeExpr::from_catalog_text("timestamptz"),
            ColumnKind::Timestamp,
            CatalogType::Unknown,
            false,
            ReadForm::Native,
        );

        assert_eq!(stamp.fractional_digits(), None);
    }

    #[test]
    fn a_decimal_reads_its_scale_and_defaults_it_to_zero() {
        let scaled = ColumnType::new(
            SqlTypeExpr::from_catalog_text("numeric(38,10)"),
            ColumnKind::Decimal,
            CatalogType::Unknown,
            false,
            ReadForm::Native,
        );
        let whole = ColumnType::new(
            SqlTypeExpr::from_catalog_text("numeric(10)"),
            ColumnKind::Decimal,
            CatalogType::Unknown,
            false,
            ReadForm::Native,
        );

        assert_eq!(scaled.decimal_scale(), Some(10));
        assert_eq!(whole.decimal_scale(), Some(0));
    }

    #[test]
    fn a_length_is_not_read_as_a_precision() {
        let text = ColumnType::new(
            SqlTypeExpr::from_catalog_text("varchar(255)"),
            ColumnKind::Text(crate::column::TextKind::Variable),
            CatalogType::Unknown,
            true,
            ReadForm::Native,
        );

        assert_eq!(text.fractional_digits(), None);
        assert_eq!(text.decimal_scale(), None);
    }

    #[test]
    fn untyped_text_reads_as_server_text() {
        let column = ColumnType::untyped_text(SqlTypeExpr::from_catalog_text("geography"));

        assert_eq!(column.kind(), ColumnKind::Other);
        assert_eq!(column.read_form(), ReadForm::ServerText);
        assert_eq!(column.catalog(), &CatalogType::Unknown);
        assert!(column.dynamic_storage());
        assert_eq!(column.name().as_sql(), "geography");
    }
}
