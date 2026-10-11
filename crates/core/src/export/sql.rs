use std::io::Write;

use super::error::ExportError;
use super::file::{ResultWriter, SqlTarget};
use super::supports_sql_literals;
use crate::query::{ColumnInfo, Value};
use crate::sql_literal::build_insert_literal;

#[derive(Debug)]
pub(crate) struct SqlWriter {
    driver_id: String,
    schema: Option<String>,
    table: String,
    columns: Vec<ColumnInfo>,
}

impl SqlWriter {
    pub(crate) fn new(target: &SqlTarget<'_>) -> Result<Self, ExportError> {
        if !supports_sql_literals(target.driver_id) {
            return Err(ExportError::SqlLiteralsUnsupported {
                driver_id: target.driver_id.to_string(),
            });
        }
        Ok(Self {
            driver_id: target.driver_id.to_string(),
            schema: target.schema.map(str::to_string),
            table: target.table.to_string(),
            columns: Vec::new(),
        })
    }
}

impl ResultWriter for SqlWriter {
    fn begin(&mut self, _output: &mut dyn Write, columns: &[ColumnInfo]) -> Result<(), ExportError> {
        self.columns = columns.to_vec();
        Ok(())
    }

    fn write_row(&mut self, output: &mut dyn Write, _index: usize, row: &[Value]) -> Result<(), ExportError> {
        let statement = build_insert_literal(&self.driver_id, self.schema.as_deref(), &self.table, &self.columns, row)?;
        writeln!(output, "{statement}")?;
        Ok(())
    }

    fn finish(&mut self, _output: &mut dyn Write) -> Result<(), ExportError> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::export::test_support::column;

    fn target<'a>(driver_id: &'a str, schema: Option<&'a str>, table: &'a str) -> SqlTarget<'a> {
        SqlTarget {
            driver_id,
            schema,
            table,
        }
    }

    fn render(target: &SqlTarget<'_>, columns: &[ColumnInfo], rows: &[Vec<Value>]) -> String {
        let mut writer = SqlWriter::new(target).unwrap();
        let mut output: Vec<u8> = Vec::new();
        writer.begin(&mut output, columns).unwrap();
        for (index, row) in rows.iter().enumerate() {
            writer.write_row(&mut output, index, row).unwrap();
        }
        writer.finish(&mut output).unwrap();
        String::from_utf8(output).unwrap()
    }

    #[test]
    fn a_driver_without_sql_literals_is_refused_instead_of_writing_a_wrong_statement() {
        for driver_id in ["mongodb", "redis"] {
            let error = SqlWriter::new(&target(driver_id, None, "people")).unwrap_err();
            assert!(
                matches!(&error, ExportError::SqlLiteralsUnsupported { driver_id: reported } if reported == driver_id),
                "{error:?}"
            );
        }
    }

    #[test]
    fn one_insert_is_written_for_each_row_and_the_table_is_qualified_and_quoted() {
        let sql = render(
            &target("postgres", Some("public"), "people"),
            &[column("id"), column("name")],
            &[
                vec![Value::Int(1), Value::Text("Ada".into())],
                vec![Value::Int(2), Value::Null],
            ],
        );

        assert_eq!(
            sql,
            "INSERT INTO \"public\".\"people\" (\"id\", \"name\") VALUES (1, 'Ada');\n\
             INSERT INTO \"public\".\"people\" (\"id\", \"name\") VALUES (2, NULL);\n"
        );
    }

    #[test]
    fn sql_export_uses_engine_generated_identity_values() {
        let mut id = column("id");
        id.is_auto_increment = true;
        let columns = [id, column("note")];
        let rows = [vec![Value::Int(7), Value::Text("copy".into())]];
        assert_eq!(
            render(&target("postgres", None, "people"), &columns, &rows),
            "INSERT INTO \"people\" (\"note\") VALUES ('copy');\n"
        );
        assert_eq!(
            render(&target("mssql", None, "people"), &columns, &rows),
            "INSERT INTO [people] ([note]) VALUES (N'copy');\n"
        );
        assert_eq!(
            render(&target("mysql", None, "people"), &columns, &rows),
            "INSERT INTO `people` (`id`, `note`) VALUES (7, 'copy');\n"
        );
    }

    #[test]
    fn a_value_and_a_column_name_cannot_close_the_statement_they_sit_in() {
        let sql = render(
            &target("mysql", None, "people`; DROP TABLE people; --"),
            &[column("name`x")],
            &[vec![Value::Text("O'Reilly\\".into())]],
        );

        assert_eq!(
            sql,
            "INSERT INTO `people``; DROP TABLE people; --` (`name``x`) VALUES (_utf8mb4 X'4f275265696c6c795c');\n"
        );
    }
}
