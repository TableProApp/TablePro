// What the tools in core/crates/mcp answer. Fields this command does not show are left out.

use std::fmt;

use serde::Deserialize;
use serde::de::{DeserializeOwned, Deserializer, IgnoredAny, MapAccess, SeqAccess, Visitor};
use serde_json::value::RawValue;

use crate::command_error::CommandError;
use crate::output::{Cell, Table};

pub(crate) fn parse<T: DeserializeOwned>(text: &str) -> Result<T, CommandError> {
    serde_json::from_str(text).map_err(|error| CommandError::Answer(error.to_string()))
}

#[derive(Deserialize)]
pub(crate) struct ConnectionList {
    pub(crate) connections: Vec<ListedConnection>,
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct ListedConnection {
    pub(crate) id: String,
    pub(crate) name: String,
    #[serde(rename = "type")]
    pub(crate) kind: String,
    #[serde(default)]
    pub(crate) is_open: bool,
}

#[derive(Deserialize)]
pub(crate) struct ConnectAnswer {
    pub(crate) status: String,
}

// core/crates/mcp/src/collected_results.rs. This command says it in its own words, naming --limit.
const TRUNCATED_NOTE: &str =
    "A result set has more rows than the limit; ask for fewer with a WHERE clause or raise max_rows.";

#[derive(Deserialize)]
pub(crate) struct Results {
    #[serde(default)]
    pub(crate) result_sets: Vec<ResultSet>,
    pub(crate) rows_affected: Option<u64>,
    #[serde(default)]
    pub(crate) notices: Vec<String>,
    #[serde(default)]
    notes: Vec<String>,
}

impl Results {
    pub(crate) fn notes(&self) -> impl Iterator<Item = &str> {
        self.notes
            .iter()
            .map(String::as_str)
            .filter(|note| *note != TRUNCATED_NOTE)
    }
}

#[derive(Deserialize)]
pub(crate) struct ResultSet {
    columns: Vec<ResultColumn>,
    rows: Vec<Row>,
    #[serde(default)]
    pub(crate) truncated: bool,
}

#[derive(Deserialize)]
struct ResultColumn {
    name: String,
}

impl ResultSet {
    pub(crate) fn to_table(&self) -> Table {
        Table {
            columns: self.columns.iter().map(|column| column.name.clone()).collect(),
            rows: self.rows.iter().map(|row| row.0.clone()).collect(),
        }
    }
}

// A row object lists its keys in column order, so its values are read by position:
// a key is the export's unique name, which can differ from the column's.
struct Row(Vec<Cell>);

impl<'de> Deserialize<'de> for Row {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(RowVisitor)
    }
}

struct RowVisitor;

impl<'de> Visitor<'de> for RowVisitor {
    type Value = Row;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("a row object")
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Row, A::Error> {
        let mut cells = Vec::new();
        while map.next_key::<IgnoredAny>()?.is_some() {
            let value: Box<RawValue> = map.next_value()?;
            cells.push(Cell::from_raw(&value));
        }
        Ok(Row(cells))
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Row, A::Error> {
        let mut cells = Vec::new();
        while let Some(value) = seq.next_element::<Box<RawValue>>()? {
            cells.push(Cell::from_raw(&value));
        }
        Ok(Row(cells))
    }
}

#[derive(Deserialize)]
pub(crate) struct DatabaseList {
    pub(crate) databases: Vec<ListedDatabase>,
}

#[derive(Deserialize)]
pub(crate) struct ListedDatabase {
    pub(crate) name: String,
    #[serde(default)]
    pub(crate) is_current: bool,
}

#[derive(Deserialize)]
pub(crate) struct SchemaList {
    pub(crate) schemas: Vec<ListedSchema>,
}

#[derive(Deserialize)]
pub(crate) struct ListedSchema {
    pub(crate) name: String,
    #[serde(default)]
    pub(crate) is_default: bool,
    #[serde(default)]
    pub(crate) is_system: bool,
}

#[derive(Deserialize)]
pub(crate) struct TableList {
    pub(crate) tables: Vec<ListedTable>,
}

#[derive(Deserialize)]
pub(crate) struct ListedTable {
    pub(crate) name: String,
    pub(crate) schema: Option<String>,
    pub(crate) kind: String,
}

#[derive(Deserialize)]
pub(crate) struct TableDescription {
    pub(crate) columns: Vec<DescribedColumn>,
    #[serde(default)]
    pub(crate) indexes: Vec<DescribedIndex>,
    #[serde(default)]
    pub(crate) foreign_keys: Vec<DescribedForeignKey>,
}

#[derive(Deserialize)]
pub(crate) struct DescribedColumn {
    pub(crate) name: String,
    pub(crate) data_type: String,
    #[serde(default)]
    pub(crate) is_nullable: bool,
    #[serde(default)]
    pub(crate) is_primary_key: bool,
    #[serde(default)]
    pub(crate) is_auto_increment: bool,
    #[serde(default)]
    pub(crate) is_generated: bool,
    pub(crate) default_value: Option<String>,
    pub(crate) comment: Option<String>,
}

#[derive(Deserialize)]
pub(crate) struct DescribedIndex {
    pub(crate) name: String,
    pub(crate) columns: Vec<String>,
    #[serde(default)]
    pub(crate) is_unique: bool,
    #[serde(default)]
    pub(crate) is_primary: bool,
    pub(crate) predicate: Option<String>,
}

#[derive(Deserialize)]
pub(crate) struct DescribedForeignKey {
    pub(crate) name: String,
    pub(crate) columns: Vec<String>,
    pub(crate) referenced_schema: Option<String>,
    pub(crate) referenced_table: String,
    pub(crate) referenced_columns: Vec<String>,
    pub(crate) on_delete: Option<String>,
    pub(crate) on_update: Option<String>,
}

#[derive(Deserialize)]
pub(crate) struct TableDdl {
    pub(crate) ddl: String,
}

#[derive(Deserialize)]
pub(crate) struct ExportAnswer {
    pub(crate) exports: Vec<Export>,
    #[serde(default)]
    pub(crate) notes: Vec<String>,
}

#[derive(Deserialize)]
pub(crate) struct Export {
    pub(crate) table: String,
    pub(crate) row_count: usize,
    #[serde(default)]
    pub(crate) truncated: bool,
    pub(crate) data: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_result_set_reads_its_rows_by_position_with_exact_numbers() {
        let text = r#"{"result_sets":[{"columns":[{"name":"id","type":"bigint"},{"name":"id","type":"text"}],
            "rows":[{"id":18446744073709551615,"id_2":"x"},{"id":null,"id_2":""}],"row_count":2,"truncated":true}],
            "execution_time_ms":3}"#;

        let results: Results = parse(text).expect("a results document");

        let set = &results.result_sets[0];
        assert!(set.truncated);
        assert_eq!(
            set.to_table(),
            Table {
                columns: vec!["id".to_owned(), "id".to_owned()],
                rows: vec![
                    vec![Cell::literal("18446744073709551615"), Cell::text("x")],
                    vec![Cell::Null, Cell::text("")],
                ],
            }
        );
        assert_eq!(results.rows_affected, None);
    }

    #[test]
    fn a_write_reads_its_rows_affected() {
        let results: Results =
            parse(r#"{"result_sets":[],"rows_affected":2,"execution_time_ms":1}"#).expect("a results document");

        assert!(results.result_sets.is_empty());
        assert_eq!(results.rows_affected, Some(2));
    }

    #[test]
    fn notes_are_read_and_the_row_limit_one_is_left_to_this_command() {
        let results: Results = parse(
            r#"{"result_sets":[],"execution_time_ms":1,"notes":["Some values could not be decoded by TablePro and are shown as null.",
            "A result set has more rows than the limit; ask for fewer with a WHERE clause or raise max_rows."]}"#,
        )
        .expect("a results document");
        let export: ExportAnswer = parse(
            r#"{"format":"csv","exports":[],"notes":["Some values could not be decoded by TablePro and are written as null."]}"#,
        )
        .expect("an export document");

        assert_eq!(
            results.notes().collect::<Vec<_>>(),
            ["Some values could not be decoded by TablePro and are shown as null."]
        );
        assert_eq!(
            export.notes,
            ["Some values could not be decoded by TablePro and are written as null."]
        );
    }

    #[test]
    fn an_answer_of_another_shape_is_reported() {
        let refused = parse::<Results>("not json");

        assert!(matches!(refused, Err(CommandError::Answer(_))));
    }
}
