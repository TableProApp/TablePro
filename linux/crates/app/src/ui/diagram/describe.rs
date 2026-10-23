//! What a screen reader says for a table in the diagram: sighted users
//! read the same from its card and its lines.

use super::model::{DiagramColumn, SchemaDiagram};
use crate::i18n::{gettext_f, ngettext_f, pgettext};

/// The table's columns and the tables it is joined to.
pub(crate) fn table_description(diagram: &SchemaDiagram, table: usize) -> String {
    let Some(found) = diagram.tables.get(table) else {
        return String::new();
    };
    let count = found.columns.len();
    let mut sentences = vec![ngettext_f(
        "{n} column.",
        "{n} columns.",
        u32::try_from(count).unwrap_or(u32::MAX),
        &[("n", &count.to_string())],
    )];
    let (references, referenced_by) = diagram.neighbours(table);
    if !references.is_empty() {
        sentences.push(gettext_f("References {tables}.", &[("tables", &references.join(", "))]));
    }
    if !referenced_by.is_empty() {
        sentences.push(gettext_f(
            "Referenced by {tables}.",
            &[("tables", &referenced_by.join(", "))],
        ));
    }
    if !found.columns.is_empty() {
        let columns: Vec<String> = found.columns.iter().map(column_text).collect();
        sentences.push(gettext_f("Columns: {columns}.", &[("columns", &columns.join("; "))]));
    }
    sentences.join(" ")
}

fn column_text(column: &DiagramColumn) -> String {
    let mut parts = vec![column.name.clone(), column.type_name.clone()];
    if column.primary_key {
        parts.push(pgettext("diagram column", "primary key"));
    }
    if column.foreign_key {
        parts.push(pgettext("diagram column", "foreign key"));
    }
    if column.nullable {
        parts.push(pgettext("diagram column", "optional"));
    }
    parts.retain(|part| !part.is_empty());
    parts.join(", ")
}

/// What the diagram as a whole is called.
pub(crate) fn diagram_label(schema: Option<&str>) -> String {
    match schema {
        Some(schema) => gettext_f("Tables in {schema}", &[("schema", schema)]),
        None => crate::i18n::gettext("Tables"),
    }
}

#[cfg(test)]
mod tests {
    use super::super::model::tests::{column, key, read};
    use super::*;

    #[test]
    fn a_table_is_described_with_its_columns_and_neighbours() {
        let diagram = SchemaDiagram::build(vec![
            read(
                "orders",
                vec![column("id", true, false), column("customer_id", false, true)],
                vec![key("orders_customer", &["customer_id"], None, "customers", &["id"])],
            ),
            read("customers", vec![column("id", true, false)], Vec::new()),
        ]);

        assert_eq!(
            table_description(&diagram, 1),
            "2 columns. References customers. Columns: id, integer, primary key; \
             customer_id, integer, foreign key, optional."
        );
        assert_eq!(
            table_description(&diagram, 0),
            "1 column. Referenced by orders. Columns: id, integer, primary key."
        );
        assert_eq!(table_description(&diagram, 9), "");
    }

    #[test]
    fn the_diagram_is_named_for_its_schema() {
        assert_eq!(diagram_label(Some("public")), "Tables in public");
        assert_eq!(diagram_label(None), "Tables");
    }
}
