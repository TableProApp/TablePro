use std::collections::HashSet;

use tablepro_core::IndexInfo;
use tablepro_core::sql_ddl::{DraftColumn, identifiers_fold_case};

use super::StructureMode;

pub(super) struct SaveDraft<'a> {
    pub table_name: &'a str,
    pub columns: &'a [DraftColumn],
    pub indexes: &'a [IndexInfo],
    pub mode: StructureMode,
    pub driver_id: &'a str,
}

pub(super) fn validate_save(draft: &SaveDraft<'_>) -> Result<(), String> {
    if matches!(draft.mode, StructureMode::New) && draft.table_name.trim().is_empty() {
        return Err(crate::tr!("Table name is required."));
    }
    if draft.columns.is_empty() {
        return Err(crate::tr!("At least one column is required."));
    }
    for col in draft.columns {
        validate_column(col)?;
    }
    let fold = identifiers_fold_case(draft.driver_id);
    if let Some(name) = first_duplicate(draft.columns.iter().map(|col| col.name.as_str()), fold) {
        return Err(crate::tr!("Duplicate column name: {name}").replace("{name}", name));
    }
    let index_names = draft
        .indexes
        .iter()
        .map(|index| index.name.as_str())
        .filter(|name| !name.is_empty());
    if let Some(name) = first_duplicate(index_names, fold) {
        return Err(crate::tr!("Duplicate index name: {name}").replace("{name}", name));
    }
    Ok(())
}

fn validate_column(col: &DraftColumn) -> Result<(), String> {
    if col.name.trim().is_empty() {
        return Err(crate::tr!("Every column needs a name."));
    }
    if col.data_type.trim().is_empty() {
        return Err(crate::tr!("Column {name} needs a type.").replace("{name}", &col.name));
    }
    if col.primary_key && col.nullable {
        return Err(crate::tr!("Primary key columns must be NOT NULL: {name}").replace("{name}", &col.name));
    }
    Ok(())
}

fn first_duplicate<'a>(names: impl Iterator<Item = &'a str>, fold: bool) -> Option<&'a str> {
    let mut seen = HashSet::new();
    names
        .into_iter()
        .find(|name| !seen.insert(if fold { name.to_lowercase() } else { (*name).to_owned() }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn column(name: &str) -> DraftColumn {
        DraftColumn {
            original: None,
            name: name.into(),
            data_type: "integer".into(),
            nullable: true,
            primary_key: false,
            auto_increment: false,
            default_value: None,
            comment: None,
            collation: None,
        }
    }

    fn index(name: &str) -> IndexInfo {
        IndexInfo {
            name: name.into(),
            columns: vec!["a".into()],
            unique: false,
            primary: false,
            predicate: None,
            constraint: None,
            has_expression_key: false,
        }
    }

    fn validate(driver_id: &str, columns: &[DraftColumn], indexes: &[IndexInfo]) -> Result<(), String> {
        validate_save(&SaveDraft {
            table_name: "items",
            columns,
            indexes,
            mode: StructureMode::Edit,
            driver_id,
        })
    }

    #[test]
    fn column_names_differing_only_in_case_are_refused_where_names_fold() {
        for driver_id in ["mysql", "sqlite", "mssql", "duckdb"] {
            assert!(
                validate(driver_id, &[column("Amount"), column("amount")], &[]).is_err(),
                "{driver_id}"
            );
        }
    }

    #[test]
    fn postgres_keeps_quoted_names_that_differ_only_in_case() {
        assert!(validate("postgres", &[column("Amount"), column("amount")], &[]).is_ok());
        assert!(validate("postgres", &[column("amount"), column("amount")], &[]).is_err());
    }

    #[test]
    fn duplicate_index_names_are_refused() {
        let columns = [column("a")];
        assert!(validate("postgres", &columns, &[index("by_a"), index("by_a")]).is_err());
        assert!(validate("mysql", &columns, &[index("By_A"), index("by_a")]).is_err());
        assert!(validate("postgres", &columns, &[index("By_A"), index("by_a")]).is_ok());
    }
}
