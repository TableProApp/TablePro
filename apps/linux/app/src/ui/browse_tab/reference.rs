use relm4::ComponentSender;

use tablepro_core::{FilterSet, ForeignKeyInfo, Value};

use super::*;

#[derive(Debug)]
pub(crate) struct ReferencedRowTarget {
    pub(crate) foreign_key: String,
    pub(crate) schema: Option<String>,
    pub(crate) table: String,
    pub(crate) filter: FilterSet,
}

pub(super) fn reference_targets(
    foreign_keys: &[ForeignKeyInfo],
    own_schema: Option<&str>,
    column: &str,
    row: &[(String, Value)],
) -> Result<Vec<ReferencedRowTarget>, String> {
    let candidates: Vec<_> = foreign_keys
        .iter()
        .filter(|candidate| candidate.columns.iter().any(|name| name == column))
        .collect();
    if candidates.is_empty() {
        return Err(crate::tr!("This column is not a foreign key"));
    }
    let (targets, errors): (Vec<_>, Vec<_>) = candidates
        .into_iter()
        .map(|foreign_key| reference_target(foreign_key, own_schema, row))
        .partition(Result::is_ok);
    if targets.is_empty() {
        return Err(errors.into_iter().find_map(Result::err).unwrap_or_default());
    }
    Ok(targets.into_iter().flatten().collect())
}

fn reference_target(
    foreign_key: &ForeignKeyInfo,
    own_schema: Option<&str>,
    row: &[(String, Value)],
) -> Result<ReferencedRowTarget, String> {
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
    Ok(ReferencedRowTarget {
        foreign_key: foreign_key.name.clone(),
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
        let output = match reference_targets(&self.foreign_keys, self.schema.as_deref(), column, row) {
            Ok(mut targets) if targets.len() == 1 => {
                let target = targets.remove(0);
                BrowseTabOutput::OpenReferencedRow {
                    schema: target.schema,
                    table: target.table,
                    filter: target.filter,
                }
            }
            Ok(targets) => BrowseTabOutput::ChooseReferencedRow(targets),
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
        let target = reference_targets(
            &keys,
            Some("public"),
            "customer_id",
            &row(&[("order_id", Value::Int(7)), ("customer_id", Value::Int(42))]),
        )
        .unwrap();
        assert_eq!(target[0].schema.as_deref(), Some("sales"));
        assert_eq!(target[0].table, "customers");
        assert_eq!(target[0].filter.rules.len(), 1);
        assert_eq!(target[0].filter.rules[0].column, "id");
        assert_eq!(target[0].filter.rules[0].op, FilterOp::Eq);
    }

    #[test]
    fn a_usable_foreign_key_is_still_offered_when_a_sibling_key_has_a_null_column() {
        let keys = [
            foreign_key(&["tenant", "customer"], &["tenant_id", "id"], None),
            foreign_key(&["tenant", "org"], &["tenant_id", "id"], None),
        ];
        let targets = reference_targets(
            &keys,
            None,
            "tenant",
            &row(&[
                ("tenant", Value::Int(1)),
                ("customer", Value::Null),
                ("org", Value::Int(5)),
            ]),
        )
        .unwrap();
        assert_eq!(targets.len(), 1);
        assert_eq!(targets[0].filter.rules.len(), 2);
    }

    #[test]
    fn a_reference_without_a_schema_stays_in_the_current_schema() {
        let keys = [foreign_key(&["customer_id"], &["id"], None)];
        let target = reference_targets(
            &keys,
            Some("public"),
            "customer_id",
            &row(&[("customer_id", Value::Int(1))]),
        )
        .unwrap();
        assert_eq!(target[0].schema.as_deref(), Some("public"));
    }

    #[test]
    fn a_composite_reference_filters_every_referenced_column_from_the_same_row() {
        let keys = [foreign_key(&["tenant", "customer"], &["tenant_id", "id"], None)];
        let target = reference_targets(
            &keys,
            None,
            "customer",
            &row(&[("tenant", Value::Int(3)), ("customer", Value::Int(9))]),
        )
        .unwrap();
        let columns: Vec<&str> = target[0].filter.rules.iter().map(|rule| rule.column.as_str()).collect();
        assert_eq!(columns, ["tenant_id", "id"]);
    }

    #[test]
    fn a_shared_column_returns_every_matching_foreign_key_target() {
        let mut organization_key = foreign_key(&["tenant", "organization"], &["tenant_id", "id"], Some("orgs"));
        organization_key.ref_table = "organizations".into();
        let keys = [
            foreign_key(&["tenant", "customer"], &["tenant_id", "id"], Some("sales")),
            organization_key,
        ];
        let targets = reference_targets(
            &keys,
            Some("public"),
            "tenant",
            &row(&[
                ("tenant", Value::Int(3)),
                ("customer", Value::Int(9)),
                ("organization", Value::Int(12)),
            ]),
        )
        .unwrap();

        assert_eq!(targets.len(), 2);
        assert_eq!(targets[0].schema.as_deref(), Some("sales"));
        assert_eq!(
            targets[0]
                .filter
                .rules
                .iter()
                .map(|rule| rule.column.as_str())
                .collect::<Vec<_>>(),
            ["tenant_id", "id"]
        );
        assert_eq!(targets[1].schema.as_deref(), Some("orgs"));
        assert_eq!(targets[1].table, "organizations");
        assert_eq!(
            targets[1]
                .filter
                .rules
                .iter()
                .map(|rule| rule.column.as_str())
                .collect::<Vec<_>>(),
            ["tenant_id", "id"]
        );
    }

    #[test]
    fn refusals_say_why_and_never_build_a_filter() {
        let keys = [foreign_key(&["tenant", "customer"], &["tenant_id", "id"], None)];
        assert!(reference_targets(&keys, None, "other", &row(&[])).is_err());
        assert!(reference_targets(&keys, None, "customer", &row(&[("customer", Value::Int(9))])).is_err());
        assert!(
            reference_targets(
                &keys,
                None,
                "customer",
                &row(&[("tenant", Value::Null), ("customer", Value::Int(9))])
            )
            .is_err()
        );
    }
}
