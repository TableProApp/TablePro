use tablepro_core::DriverError;

use super::catalog_cells::CatalogCells;
use crate::flavour::MySqlFlavour;

/// One row of `information_schema.COLUMNS`, the columns of a table in
/// order. MariaDB has no SRS_ID, so its query selects a NULL there.
const MYSQL_COLUMNS_SQL: &str = "\
SELECT COLUMN_NAME, DATA_TYPE, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, EXTRA,
       NUMERIC_PRECISION, NUMERIC_SCALE, DATETIME_PRECISION, CHARACTER_MAXIMUM_LENGTH,
       CHARACTER_SET_NAME, COLLATION_NAME, GENERATION_EXPRESSION, COLUMN_COMMENT, SRS_ID
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = COALESCE(?, DATABASE()) AND TABLE_NAME = ?
ORDER BY ORDINAL_POSITION";

const MARIADB_COLUMNS_SQL: &str = "\
SELECT COLUMN_NAME, DATA_TYPE, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, EXTRA,
       NUMERIC_PRECISION, NUMERIC_SCALE, DATETIME_PRECISION, CHARACTER_MAXIMUM_LENGTH,
       CHARACTER_SET_NAME, COLLATION_NAME, GENERATION_EXPRESSION, COLUMN_COMMENT, NULL AS SRS_ID
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = COALESCE(?, DATABASE()) AND TABLE_NAME = ?
ORDER BY ORDINAL_POSITION";

pub(crate) fn columns_sql(flavour: MySqlFlavour) -> &'static str {
    match flavour {
        MySqlFlavour::MySql => MYSQL_COLUMNS_SQL,
        MySqlFlavour::MariaDb => MARIADB_COLUMNS_SQL,
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct MySqlColumnRow {
    pub name: String,
    pub data_type: String,
    pub column_type: String,
    pub nullable: bool,
    pub column_key: String,
    pub default: Option<String>,
    pub extra: String,
    pub numeric_precision: Option<u64>,
    pub numeric_scale: Option<u64>,
    pub datetime_precision: Option<u64>,
    pub character_maximum_length: Option<u64>,
    pub character_set: Option<String>,
    pub collation: Option<String>,
    pub generation_expression: Option<String>,
    pub comment: Option<String>,
    pub srs_id: Option<u64>,
}

impl MySqlColumnRow {
    pub(crate) fn from_cells(cells: &CatalogCells) -> Result<Self, DriverError> {
        Ok(Self {
            name: cells.required_text(0)?,
            data_type: cells.required_text(1)?,
            column_type: cells.required_text(2)?,
            nullable: cells.text(3)?.as_deref() == Some("YES"),
            column_key: cells.text(4)?.unwrap_or_default(),
            default: cells.text(5)?,
            extra: cells.text(6)?.unwrap_or_default(),
            numeric_precision: cells.number(7)?,
            numeric_scale: cells.number(8)?,
            datetime_precision: cells.number(9)?,
            character_maximum_length: cells.number(10)?,
            character_set: cells.text(11)?,
            collation: cells.text(12)?,
            generation_expression: cells.text(13)?.filter(|expression| !expression.is_empty()),
            // MySQL has no "no comment": a column without one carries the
            // empty string.
            comment: cells.text(14)?.filter(|comment| !comment.is_empty()),
            srs_id: cells.number(15)?,
        })
    }
}
