use crate::column::{ColumnKind, ColumnType, ResultColumn};
use crate::ddl::{InboundForeignKey, OutboundForeignKey};
use crate::edit::{EditText, edit_text, parse_filter_text};
use crate::filter::{Combinator, FilterOp, FilterRule, FilterSet, FilterValue};
use crate::meta::TableRef;
use crate::value::Value;

use super::ReferenceError;

/// The rows a foreign key leads to from one row: the table at the other
/// end, filtered on every column of the key to the row's values.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RowReference {
    pub table: TableRef,
    pub filter: FilterSet,
}

impl RowReference {
    /// The row that `key`, a key of `source`, points at from the row
    /// whose cells are `values` under `columns`.
    pub fn referenced(
        source: &TableRef,
        key: &OutboundForeignKey,
        columns: &[ResultColumn],
        values: &[Value],
    ) -> Result<Self, ReferenceError> {
        let OutboundForeignKey {
            key,
            parent_compares_alike,
        } = key;
        let cells = key_cells(&key.columns, columns, values)?;
        let filter = key_filter(&key.name, cells, &key.ref_columns)?;
        let table = target(source, key.ref_schema.as_deref(), &key.ref_table)?;
        compared_alike(*parent_compares_alike, &table)?;
        Ok(Self { table, filter })
    }

    /// The rows of another table whose `key` points at the row of
    /// `source` whose cells are `values` under `columns`.
    pub fn referencing(
        source: &TableRef,
        key: &InboundForeignKey,
        columns: &[ResultColumn],
        values: &[Value],
    ) -> Result<Self, ReferenceError> {
        let cells = key_cells(&key.referenced_columns, columns, values)?;
        let filter = key_filter(&key.name, cells, &key.columns)?;
        let table = target(source, key.table.schema.as_deref(), &key.table.name)?;
        compared_alike(key.child_compares_alike, &table)?;
        Ok(Self { table, filter })
    }
}

fn compared_alike(alike: bool, table: &TableRef) -> Result<(), ReferenceError> {
    match alike {
        true => Ok(()),
        false => Err(ReferenceError::ComparedOtherwise {
            table: table.name.clone(),
        }),
    }
}

/// The row's cell under each of `names`, in key order.
fn key_cells<'a>(
    names: &[String],
    columns: &'a [ResultColumn],
    values: &'a [Value],
) -> Result<Vec<(&'a ColumnType, &'a Value)>, ReferenceError> {
    let mut cells = Vec::with_capacity(names.len());
    for name in names {
        let cell = columns
            .iter()
            .position(|column| column.name == *name)
            .and_then(|index| Some((&columns.get(index)?.column_type, values.get(index)?)));
        let Some((column_type, value)) = cell else {
            return Err(ReferenceError::MissingColumn { column: name.clone() });
        };
        if matches!(value, Value::Null) {
            return Err(ReferenceError::NullKey);
        }
        cells.push((column_type, value));
    }
    Ok(cells)
}

fn key_filter(key: &str, cells: Vec<(&ColumnType, &Value)>, targets: &[String]) -> Result<FilterSet, ReferenceError> {
    if cells.is_empty() || cells.len() != targets.len() {
        return Err(ReferenceError::UnevenKey { key: key.to_owned() });
    }
    let rules = cells
        .into_iter()
        .zip(targets)
        .map(|((column_type, value), target)| {
            let text = filter_text(value, column_type)
                .ok_or_else(|| ReferenceError::NoFilterText { column: target.clone() })?;
            Ok(FilterRule {
                column: target.clone(),
                op: FilterOp::Eq,
                value: Some(FilterValue::Single(text)),
            })
        })
        .collect::<Result<_, ReferenceError>>()?;
    Ok(FilterSet {
        combinator: Combinator::And,
        rules,
        extra_sql: None,
    })
}

/// The text the filter parses back into `value`: a blob in the `0x`
/// form an export writes, anything else as an editor would start from.
/// The other side reads it under a type that compares alike with this
/// column's, so text this column's own type does not read, such as a
/// word SQLite keeps in an INTEGER column, has no filter.
fn filter_text(value: &Value, column_type: &ColumnType) -> Option<String> {
    let text = match value {
        Value::Bytes(bytes) if matches!(column_type.kind, ColumnKind::Bytes { .. }) => {
            format!("0x{}", crate::hex::encode_lower(bytes))
        }
        Value::Bytes(_) => return None,
        other => match edit_text(other, column_type) {
            EditText::Editable(text) => text,
            EditText::ReadOnly(_) => return None,
        },
    };
    parse_filter_text(&text, column_type).is_ok().then_some(text)
}

fn target(source: &TableRef, schema: Option<&str>, name: &str) -> Result<TableRef, ReferenceError> {
    if source.schema.is_some() && schema.is_none() {
        return Err(ReferenceError::UnknownSchema { table: name.to_owned() });
    }
    Ok(TableRef::new(schema.map(str::to_owned), name.to_owned()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text_column(name: &str) -> ResultColumn {
        ResultColumn::new(name, ColumnType::untyped_text("text"))
    }

    fn typed(name: &str, kind: ColumnKind) -> ResultColumn {
        ResultColumn::new(
            name,
            ColumnType {
                name: "t".to_owned(),
                kind,
                catalog: None,
                dynamic_storage: false,
                read_form: crate::column::ReadForm::Native,
            },
        )
    }

    fn orders() -> TableRef {
        TableRef::new(Some("sales".to_owned()), "orders".to_owned())
    }

    fn key(columns: &[&str], ref_schema: Option<&str>, ref_columns: &[&str]) -> OutboundForeignKey {
        OutboundForeignKey {
            key: crate::ForeignKeyInfo {
                name: "orders_customer_fkey".to_owned(),
                columns: columns.iter().map(|name| (*name).to_owned()).collect(),
                ref_schema: ref_schema.map(str::to_owned),
                ref_table: "customers".to_owned(),
                ref_columns: ref_columns.iter().map(|name| (*name).to_owned()).collect(),
                on_delete: None,
                on_update: None,
            },
            parent_compares_alike: true,
        }
    }

    fn eq(column: &str, text: &str) -> FilterRule {
        FilterRule {
            column: column.to_owned(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single(text.to_owned())),
        }
    }

    #[test]
    fn a_composite_key_filters_on_every_column_in_key_order() {
        let columns = [text_column("id"), text_column("region"), text_column("customer_id")];
        let values = [
            Value::Int(9),
            Value::Text("eu ".to_owned()),
            Value::Text("42".to_owned()),
        ];
        let key = key(&["customer_id", "region"], Some("crm"), &["id", "region"]);

        let reference = RowReference::referenced(&orders(), &key, &columns, &values).expect("a reference");

        assert_eq!(
            reference.table,
            TableRef::new(Some("crm".to_owned()), "customers".to_owned())
        );
        assert_eq!(reference.filter.combinator, Combinator::And);
        assert_eq!(reference.filter.rules, vec![eq("id", "42"), eq("region", "eu ")]);
        assert_eq!(reference.filter.extra_sql, None);
    }

    #[test]
    fn a_null_in_any_column_leaves_nothing_to_follow() {
        let columns = [text_column("customer_id"), text_column("region")];
        let values = [Value::Text("42".to_owned()), Value::Null];
        let key = key(&["customer_id", "region"], Some("sales"), &["id", "region"]);

        let error = RowReference::referenced(&orders(), &key, &columns, &values).expect_err("a NULL part");

        assert_eq!(error, ReferenceError::NullKey);
        assert!(error.leaves_nothing_to_follow());
    }

    #[test]
    fn an_empty_text_is_a_value_not_a_null() {
        let columns = [text_column("code")];
        let key = key(&["code"], Some("sales"), &["code"]);

        let reference = RowReference::referenced(&orders(), &key, &columns, &[Value::Text(String::new())])
            .expect("an empty string is a key value");

        assert_eq!(reference.filter.rules, vec![eq("code", "")]);
    }

    #[test]
    fn a_blob_is_written_in_its_hex_form() {
        let columns = [typed(
            "customer_uuid",
            ColumnKind::Bytes {
                length: crate::column::TextLength::Fixed(16),
            },
        )];
        let key = key(&["customer_uuid"], Some("sales"), &["uuid"]);

        let reference = RowReference::referenced(&orders(), &key, &columns, &[Value::Bytes(vec![0x0a, 0xff])])
            .expect("a binary key");

        assert_eq!(reference.filter.rules, vec![eq("uuid", "0x0aff")]);
    }

    #[test]
    fn a_blob_in_a_column_declared_as_text_is_refused_rather_than_compared_as_text() {
        let columns = [text_column("customer_code")];
        let key = key(&["customer_code"], Some("sales"), &["code"]);

        let error = RowReference::referenced(&orders(), &key, &columns, &[Value::Bytes(vec![0xab])])
            .expect_err("a blob under a text declaration");

        assert_eq!(
            error,
            ReferenceError::NoFilterText {
                column: "code".to_owned()
            }
        );
    }

    #[test]
    fn a_key_whose_sides_compare_otherwise_is_refused_and_shown() {
        let columns = [typed("weight", ColumnKind::Float(crate::column::FloatWidth::F32))];
        let mut real_to_double = key(&["weight"], Some("sales"), &["weight"]);
        real_to_double.parent_compares_alike = false;

        let error = RowReference::referenced(&orders(), &real_to_double, &columns, &[Value::Float32(0.1)])
            .expect_err("a real key into a double column");

        assert_eq!(
            error,
            ReferenceError::ComparedOtherwise {
                table: "customers".to_owned()
            }
        );
        assert!(!error.leaves_nothing_to_follow());
    }

    #[test]
    fn a_value_its_own_column_type_does_not_read_is_refused() {
        let mut integer = typed(
            "customer_id",
            ColumnKind::Integer(crate::column::IntegerKind {
                width: crate::column::IntegerWidth::W64,
                signed: true,
            }),
        );
        integer.column_type.dynamic_storage = true;
        let key = key(&["customer_id"], None, &["id"]);
        let main = TableRef::new(None, "orders".to_owned());

        let error = RowReference::referenced(
            &main,
            &key,
            std::slice::from_ref(&integer),
            &[Value::Text("n/a".to_owned())],
        )
        .expect_err("a word SQLite kept in an INTEGER column");
        let reference = RowReference::referenced(&main, &key, &[integer], &[Value::Int(7)]).expect("a number");

        assert_eq!(
            error,
            ReferenceError::NoFilterText {
                column: "id".to_owned()
            }
        );
        assert_eq!(reference.filter.rules, vec![eq("id", "7")]);
    }

    #[test]
    fn a_key_the_catalogue_could_not_pair_up_is_refused_and_shown() {
        let columns = [text_column("owner")];
        let dangling = key(&["owner"], Some("sales"), &[]);

        let error = RowReference::referenced(&orders(), &dangling, &columns, &[Value::Int(1)]).expect_err("uneven");

        assert_eq!(
            error,
            ReferenceError::UnevenKey {
                key: "orders_customer_fkey".to_owned()
            }
        );
        assert!(!error.leaves_nothing_to_follow());
    }

    #[test]
    fn a_key_with_no_schema_from_a_table_in_one_is_refused_rather_than_guessed() {
        let columns = [text_column("customer_id")];
        let unqualified = key(&["customer_id"], None, &["id"]);

        let error =
            RowReference::referenced(&orders(), &unqualified, &columns, &[Value::Int(1)]).expect_err("no schema");

        assert_eq!(
            error,
            ReferenceError::UnknownSchema {
                table: "customers".to_owned()
            }
        );
        let main = TableRef::new(None, "orders".to_owned());
        let reference = RowReference::referenced(&main, &unqualified, &columns, &[Value::Int(1)])
            .expect("an engine without schemas names none on either side");
        assert_eq!(reference.table, TableRef::new(None, "customers".to_owned()));
    }

    #[test]
    fn a_value_with_no_text_form_names_its_column() {
        let columns = [typed("shape", ColumnKind::Spatial)];
        let key = key(&["shape"], Some("sales"), &["outline"]);

        let error = RowReference::referenced(&orders(), &key, &columns, &[Value::Int(1)]).expect_err("no text");

        assert_eq!(
            error,
            ReferenceError::NoFilterText {
                column: "outline".to_owned()
            }
        );
    }

    #[test]
    fn a_missing_column_leaves_nothing_to_follow() {
        let error = RowReference::referenced(&orders(), &key(&["gone"], Some("sales"), &["id"]), &[], &[])
            .expect_err("no such column");

        assert!(error.leaves_nothing_to_follow(), "{error:?}");
    }

    #[test]
    fn rows_a_key_compares_otherwise_than_their_columns_are_refused() {
        let customers = TableRef::new(None, "customers".to_owned());
        let inbound = InboundForeignKey {
            child_compares_alike: false,
            name: "orders_customer_fkey".to_owned(),
            table: TableRef::new(None, "orders".to_owned()),
            columns: vec!["customer_code".to_owned()],
            referenced_columns: vec!["code".to_owned()],
        };

        let error = RowReference::referencing(&customers, &inbound, &[text_column("code")], &[Value::Int(1)])
            .expect_err("a NOCASE parent and a BINARY child");

        assert_eq!(
            error,
            ReferenceError::ComparedOtherwise {
                table: "orders".to_owned()
            }
        );
        assert!(!error.leaves_nothing_to_follow());
    }

    #[test]
    fn referencing_rows_filter_the_other_table_on_its_own_columns() {
        let customers = TableRef::new(Some("crm".to_owned()), "customers".to_owned());
        let columns = [text_column("id"), text_column("region")];
        let values = [Value::Int(42), Value::Text("eu".to_owned())];
        let inbound = InboundForeignKey {
            child_compares_alike: true,
            name: "orders_customer_fkey".to_owned(),
            table: orders(),
            columns: vec!["customer_id".to_owned(), "customer_region".to_owned()],
            referenced_columns: vec!["id".to_owned(), "region".to_owned()],
        };

        let reference = RowReference::referencing(&customers, &inbound, &columns, &values).expect("a reference");

        assert_eq!(reference.table, orders());
        assert_eq!(
            reference.filter.rules,
            vec![eq("customer_id", "42"), eq("customer_region", "eu")]
        );
    }
}
