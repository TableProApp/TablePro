use tablepro_core::{ColumnInfo, QualifiedTypeName};

use super::*;

pub(crate) fn scalar_enum_columns(columns: &[ColumnInfo]) -> Vec<(String, QualifiedTypeName)> {
    columns
        .iter()
        .filter(|column| !column.data_type.ends_with("[]") && !column.data_type.starts_with('_'))
        .filter_map(|column| Some((column.name.clone(), column.enum_type.clone()?)))
        .collect()
}

impl BrowseTab {
    pub(super) fn refresh_member_choices(&self) {
        let mut choices = self.choice_labels.borrow_mut();
        choices.clear();
        for column in &self.current_columns {
            if let Some(members) = mysql_enum_set_labels(&column.data_type) {
                choices.insert(column.name.clone(), members);
            }
        }
    }

    pub(super) fn apply_enum_labels(&self, labels: Vec<(String, Vec<String>)>) {
        let mut choices = self.choice_labels.borrow_mut();
        for (column, members) in labels {
            if members.is_empty() {
                choices.remove(&column);
            } else {
                choices.insert(column, (false, members));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn column(name: &str, data_type: &str, enum_type: Option<&str>) -> ColumnInfo {
        ColumnInfo {
            name: name.into(),
            data_type: data_type.into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: enum_type.map(|name| QualifiedTypeName {
                schema: "public".into(),
                name: name.into(),
            }),
            domain_type: None,
        }
    }

    #[test]
    fn only_scalar_enum_columns_are_fetched_for_members() {
        let columns = [
            column("mood", "mood", Some("mood")),
            column("moods", "mood[]", Some("mood")),
            column("legacy", "_mood", Some("mood")),
            column("name", "text", None),
        ];
        let found = scalar_enum_columns(&columns);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].0, "mood");
    }
}
