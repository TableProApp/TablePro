use relm4::ComponentSender;

use tablepro_core::{FilterSet, ForeignKeyInfo, Value};

use super::*;

pub(super) struct ReferenceTarget {
    pub(super) schema: Option<String>,
    pub(super) table: String,
    pub(super) filter: FilterSet,
}

pub(super) fn reference_target(
    foreign_keys: &[ForeignKeyInfo],
    own_schema: Option<&str>,
    column: &str,
    row: &[(String, Value)],
) -> Result<ReferenceTarget, String> {
    let foreign_key = foreign_keys
        .iter()
        .find(|candidate| candidate.columns.iter().any(|name| name == column))
        .ok_or_else(|| crate::tr!("This column is not a foreign key"))?;
    let mut rules = Vec::new();
    for (local, referenced) in foreign_key.columns.iter().zip(&foreign_key.ref_columns) {
        let value = row
            .iter()
            .find(|(name, _)| name == local)
            .map(|(_, value)| value)
            .ok_or_else(|| crate::tr!("A column of this foreign key is hidden"))?;
        if matches!(value, Value::Null) {
            return Err(crate::tr!("This foreign key is empty"));
        }
        rules.push(
            tablepro_core::equality_rule(referenced, value)
                .ok_or_else(|| crate::tr!("Values of this type can't be used as a filter"))?,
        );
    }
    Ok(ReferenceTarget {
        schema: foreign_key.ref_schema.clone().or_else(|| own_schema.map(str::to_owned)),
        table: foreign_key.ref_table.clone(),
        filter: FilterSet {
            rules,
            ..FilterSet::default()
        },
    })
}

impl BrowseTab {
    pub(super) fn go_to_reference(&self, column: &str, row: &[(String, Value)], sender: &ComponentSender<Self>) {
        let output = match reference_target(&self.foreign_keys, self.schema.as_deref(), column, row) {
            Ok(target) => BrowseTabOutput::OpenReferencedRow {
                schema: target.schema,
                table: target.table,
                filter: target.filter,
            },
            Err(message) => BrowseTabOutput::ShowToast(message),
        };
        let _ = sender.output(output);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::FilterOp;

    fn foreign_key(columns: &[&str], ref_columns: &[&str], ref_schema: Option<&str>) -> ForeignKeyInfo {
        ForeignKeyInfo {
            name: "fk".into(),
            columns: columns.iter().map(|name| name.to_string()).collect(),
            ref_schema: ref_schema.map(str::to_owned),
            ref_table: "customers".into(),
            ref_columns: ref_columns.iter().map(|name| name.to_string()).collect(),
            on_delete: None,
            on_update: None,
        }
    }

    fn row(cells: &[(&str, Value)]) -> Vec<(String, Value)> {
        cells
            .iter()
            .map(|(name, value)| (name.to_string(), value.clone()))
            .collect()
    }

    #[test]
    fn a_single_column_reference_filters_the_referenced_column_by_the_cell_value() {
        let keys = [foreign_key(&["customer_id"], &["id"], Some("sales"))];
        let target = reference_target(
            &keys,
            Some("public"),
            "customer_id",
            &row(&[("order_id", Value::Int(7)), ("customer_id", Value::Int(42))]),
        )
        .unwrap();
        assert_eq!(target.schema.as_deref(), Some("sales"));
        assert_eq!(target.table, "customers");
        assert_eq!(target.filter.rules.len(), 1);
        assert_eq!(target.filter.rules[0].column, "id");
        assert_eq!(target.filter.rules[0].op, FilterOp::Eq);
    }

    #[test]
    fn a_reference_without_a_schema_stays_in_the_current_schema() {
        let keys = [foreign_key(&["customer_id"], &["id"], None)];
        let target = reference_target(
            &keys,
            Some("public"),
            "customer_id",
            &row(&[("customer_id", Value::Int(1))]),
        )
        .unwrap();
        assert_eq!(target.schema.as_deref(), Some("public"));
    }

    #[test]
    fn a_composite_reference_filters_every_referenced_column_from_the_same_row() {
        let keys = [foreign_key(&["tenant", "customer"], &["tenant_id", "id"], None)];
        let target = reference_target(
            &keys,
            None,
            "customer",
            &row(&[("tenant", Value::Int(3)), ("customer", Value::Int(9))]),
        )
        .unwrap();
        let columns: Vec<&str> = target.filter.rules.iter().map(|rule| rule.column.as_str()).collect();
        assert_eq!(columns, ["tenant_id", "id"]);
    }

    #[test]
    fn refusals_say_why_and_never_build_a_filter() {
        let keys = [foreign_key(&["tenant", "customer"], &["tenant_id", "id"], None)];
        assert!(reference_target(&keys, None, "other", &row(&[])).is_err());
        assert!(reference_target(&keys, None, "customer", &row(&[("customer", Value::Int(9))])).is_err());
        assert!(
            reference_target(
                &keys,
                None,
                "customer",
                &row(&[("tenant", Value::Null), ("customer", Value::Int(9))])
            )
            .is_err()
        );
    }
}
