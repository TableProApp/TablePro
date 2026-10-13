use tablepro_core::DriverError;
use tablepro_core::value::Value;

use super::cells::Cells;
use super::sql_server_type::{CatalogFacts, SqlServerType};

/// Every column of one table, read from `sys.columns`.
///
/// An alias type is classified by the system type it is stored as,
/// which `TYPE_NAME(system_type_id)` names; a CLR type keeps its own
/// name. A collation is reported only where it differs from the
/// database's, which is the default a column takes, and the column after
/// it says whether its code page differs too. The last is the function
/// of the column's data mask, if it has one.
pub(crate) const COLUMNS_SQL: &str = "SELECT \
        c.name, \
        t.name, \
        CASE WHEN t.is_assembly_type = 0 AND t.user_type_id <> t.system_type_id \
             THEN TYPE_NAME(t.system_type_id) ELSE t.name END, \
        SCHEMA_NAME(t.schema_id), \
        CAST(t.is_user_defined AS int), \
        CAST(CASE WHEN t.is_assembly_type = 0 AND t.user_type_id <> t.system_type_id THEN 1 ELSE 0 END AS int), \
        CAST(CASE WHEN t.is_assembly_type = 1 AND t.is_user_defined = 1 THEN 1 ELSE 0 END AS int), \
        CAST(c.max_length AS int), \
        CAST(c.precision AS int), \
        CAST(c.scale AS int), \
        CAST(c.is_nullable AS int), \
        CAST(c.is_identity AS int), \
        CAST(c.is_computed AS int), \
        dc.definition, \
        dc.name, \
        CAST(CASE WHEN pk.column_id IS NOT NULL THEN 1 ELSE 0 END AS int), \
        CAST(ep.value AS nvarchar(max)), \
        CASE WHEN c.collation_name COLLATE DATABASE_DEFAULT \
                  <> CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS nvarchar(128)) COLLATE DATABASE_DEFAULT \
             THEN c.collation_name END, \
        CAST(c.is_sparse AS int), \
        cc.definition, \
        CAST(ISNULL(cc.is_persisted, 0) AS int), \
        CAST(CASE WHEN COLLATIONPROPERTY(c.collation_name, 'CodePage') \
                  <> COLLATIONPROPERTY(CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS nvarchar(128)), 'CodePage') \
             THEN 1 ELSE 0 END AS int), \
        mc.masking_function \
    FROM sys.columns c \
    JOIN sys.types t ON t.user_type_id = c.user_type_id \
    LEFT JOIN sys.default_constraints dc ON dc.object_id = c.default_object_id \
    LEFT JOIN sys.computed_columns cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id \
    LEFT JOIN sys.masked_columns mc ON mc.object_id = c.object_id AND mc.column_id = c.column_id \
        AND mc.is_masked = 1 \
    LEFT JOIN ( \
        SELECT ic.object_id, ic.column_id \
        FROM sys.index_columns ic \
        JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id \
        WHERE i.is_primary_key = 1 \
    ) pk ON pk.object_id = c.object_id AND pk.column_id = c.column_id \
    LEFT JOIN sys.extended_properties ep \
        ON ep.class = 1 AND ep.major_id = c.object_id AND ep.minor_id = c.column_id \
        AND ep.name = 'MS_Description' \
    WHERE c.object_id = OBJECT_ID(@P1) \
    ORDER BY c.column_id";

/// One row of `COLUMNS_SQL`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct MssqlColumnRow {
    pub(crate) name: String,
    pub(crate) sql_type: SqlServerType,
    pub(crate) nullable: bool,
    pub(crate) identity: bool,
    pub(crate) computed: bool,
    pub(crate) default_definition: Option<String>,
    pub(crate) default_constraint: Option<String>,
    pub(crate) primary_key: bool,
    pub(crate) comment: Option<String>,
    pub(crate) collation: Option<String>,
    pub(crate) sparse: bool,
    pub(crate) computed_definition: Option<String>,
    pub(crate) persisted: bool,
    pub(crate) masking_function: Option<String>,
}

impl MssqlColumnRow {
    pub(crate) fn from_values(values: &[Value]) -> Result<Self, DriverError> {
        let cells = Cells::new(values, "sys.columns");
        let type_name = cells.required_text(1)?;
        let base_type = cells.text(2).unwrap_or_else(|| type_name.clone());
        let type_schema = cells.text(3);
        let sql_type = SqlServerType::from_catalog(CatalogFacts {
            type_name: &type_name,
            base_type: &base_type,
            type_schema: type_schema.as_deref(),
            user_defined: cells.flag(4),
            alias: cells.flag(5),
            user_clr: cells.flag(6),
            max_length: cells.int(7).unwrap_or(0),
            precision: cells.int(8).unwrap_or(0),
            scale: cells.int(9).unwrap_or(0),
            foreign_code_page: cells.flag(21),
        });
        Ok(Self {
            name: cells.required_text(0)?,
            sql_type,
            nullable: cells.flag(10),
            identity: cells.flag(11),
            computed: cells.flag(12),
            default_definition: cells.text(13),
            default_constraint: cells.text(14),
            primary_key: cells.flag(15),
            comment: cells.text(16),
            collation: cells.text(17),
            sparse: cells.flag(18),
            computed_definition: cells.text(19),
            persisted: cells.flag(20),
            masking_function: cells.text(22),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(value: &str) -> Value {
        Value::Text(value.to_owned())
    }

    #[test]
    fn a_catalogue_row_reads_by_position() {
        let values = vec![
            text("price"),
            text("money"),
            text("money"),
            text("sys"),
            Value::Int(0),
            Value::Int(0),
            Value::Int(0),
            Value::Int(8),
            Value::Int(19),
            Value::Int(4),
            Value::Int(1),
            Value::Int(0),
            Value::Int(0),
            text("((0))"),
            text("DF_items_price"),
            Value::Int(0),
            text("what it costs"),
            Value::Null,
            Value::Int(0),
            Value::Null,
            Value::Int(0),
            Value::Int(0),
        ];

        let row = MssqlColumnRow::from_values(&values).unwrap();

        assert_eq!(row.name, "price");
        assert_eq!(row.sql_type.declaration(), "money");
        assert!(row.nullable);
        assert_eq!(row.default_definition.as_deref(), Some("((0))"));
        assert_eq!(row.default_constraint.as_deref(), Some("DF_items_price"));
        assert_eq!(row.comment.as_deref(), Some("what it costs"));
        assert_eq!(row.collation, None);
    }

    #[test]
    fn a_row_without_a_name_is_a_decode_error() {
        let values = vec![Value::Null, text("int")];

        assert!(matches!(
            MssqlColumnRow::from_values(&values),
            Err(DriverError::Decode { .. })
        ));
    }
}
