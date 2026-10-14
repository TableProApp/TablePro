//! A foreign key as the Add Foreign Key dialog holds it, checked on
//! every change.

use tablepro_core::ForeignKeyInfo;
use tablepro_core::ddl::ReferentialAction;
use tablepro_core::meta::TableRef;

use super::index_draft::same_name;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct ForeignKeyDraft {
    pub name: String,
    /// Each column of the key, in the table's column order, with the
    /// referenced column it pairs with once one is chosen.
    pub pairs: Vec<(String, Option<String>)>,
    pub referenced: Option<TableRef>,
    /// `None` leaves the action to the database, and the DDL says
    /// nothing about it.
    pub on_delete: Option<ReferentialAction>,
    pub on_update: Option<ReferentialAction>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ForeignKeyDraftError {
    NameMissing,
    NameTaken,
    NoTable,
    NoPairs,
    UnpairedColumn(String),
}

impl ForeignKeyDraftError {
    pub(crate) fn message(&self) -> String {
        match self {
            Self::NameMissing => crate::i18n::gettext("Foreign key name is required."),
            Self::NameTaken => crate::i18n::gettext("The table already has a foreign key with this name."),
            Self::NoTable => crate::i18n::gettext("Choose the table the key references."),
            Self::NoPairs => crate::i18n::gettext("Choose at least one column."),
            Self::UnpairedColumn(column) => {
                crate::i18n::gettext_f("Choose the column “{column}” references.", &[("column", column)])
            }
        }
    }
}

impl ForeignKeyDraft {
    /// The key, or every problem in the order the form shows its
    /// fields. `existing` are the names the table's foreign keys already
    /// take.
    pub(crate) fn validate(&self, existing: &[String]) -> Result<ForeignKeyInfo, Vec<ForeignKeyDraftError>> {
        let name = self.name.trim();
        let mut errors = Vec::new();
        if name.is_empty() {
            errors.push(ForeignKeyDraftError::NameMissing);
        } else if existing.iter().any(|taken| same_name(taken, name)) {
            errors.push(ForeignKeyDraftError::NameTaken);
        }
        if self.referenced.is_none() {
            errors.push(ForeignKeyDraftError::NoTable);
        }
        if self.pairs.is_empty() {
            errors.push(ForeignKeyDraftError::NoPairs);
        }
        errors.extend(
            self.pairs
                .iter()
                .filter(|(_, referenced)| referenced.is_none())
                .map(|(column, _)| ForeignKeyDraftError::UnpairedColumn(column.clone())),
        );
        let Some(referenced) = self.referenced.as_ref().filter(|_| errors.is_empty()) else {
            return Err(errors);
        };
        Ok(ForeignKeyInfo {
            name: name.to_owned(),
            columns: self.pairs.iter().map(|(column, _)| column.clone()).collect(),
            ref_schema: referenced.schema.clone(),
            ref_table: referenced.name.clone(),
            ref_columns: self
                .pairs
                .iter()
                .filter_map(|(_, referenced)| referenced.clone())
                .collect(),
            on_delete: self.on_delete,
            on_update: self.on_update,
        })
    }

    /// Add `column` to the key or take it out, keeping the key in the
    /// order of `columns`. An added column pairs with the column of the
    /// same name in `referenced_columns`, if there is one.
    pub(crate) fn set_checked(
        &mut self,
        columns: &[String],
        column: &str,
        checked: bool,
        referenced_columns: &[String],
    ) {
        let present = self.pairs.iter().any(|(paired, _)| paired == column);
        match (checked, present) {
            (true, false) => {
                let partner = same_column(referenced_columns, column);
                self.pairs.push((column.to_owned(), partner));
                self.pairs
                    .sort_by_key(|(paired, _)| columns.iter().position(|candidate| candidate == paired));
            }
            (false, true) => self.pairs.retain(|(paired, _)| paired != column),
            _ => {}
        }
    }

    pub(crate) fn pair(&mut self, column: &str, referenced: Option<String>) {
        if let Some((_, partner)) = self.pairs.iter_mut().find(|(paired, _)| paired == column) {
            *partner = referenced;
        }
    }

    /// The columns of a newly chosen table: each column of the key pairs
    /// with the one of the same name there, or with none.
    pub(crate) fn pair_with(&mut self, referenced_columns: &[String]) {
        for (column, partner) in &mut self.pairs {
            *partner = same_column(referenced_columns, column);
        }
    }
}

/// The exact name first, then one that differs only in case.
fn same_column(candidates: &[String], column: &str) -> Option<String> {
    candidates
        .iter()
        .find(|candidate| *candidate == column)
        .or_else(|| candidates.iter().find(|candidate| same_name(candidate, column)))
        .cloned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| (*name).to_owned()).collect()
    }

    #[test]
    fn fk_requires_table_and_complete_pairs() {
        let columns = names(&["id", "account_id", "owner"]);
        let mut draft = ForeignKeyDraft::default();

        assert_eq!(
            draft.validate(&[]),
            Err(vec![
                ForeignKeyDraftError::NameMissing,
                ForeignKeyDraftError::NoTable,
                ForeignKeyDraftError::NoPairs,
            ])
        );

        draft.name = "fk_account".to_owned();
        draft.set_checked(&columns, "account_id", true, &[]);
        draft.set_checked(&columns, "owner", true, &[]);
        assert_eq!(
            draft.validate(&names(&["FK_ACCOUNT"])),
            Err(vec![
                ForeignKeyDraftError::NameTaken,
                ForeignKeyDraftError::NoTable,
                ForeignKeyDraftError::UnpairedColumn("account_id".to_owned()),
                ForeignKeyDraftError::UnpairedColumn("owner".to_owned()),
            ])
        );

        draft.referenced = Some(TableRef::new(Some("billing".to_owned()), "accounts"));
        draft.pair_with(&names(&["id", "Owner"]));
        assert_eq!(
            draft.validate(&[]),
            Err(vec![ForeignKeyDraftError::UnpairedColumn("account_id".to_owned())])
        );

        draft.pair("account_id", Some("id".to_owned()));
        let key = draft.validate(&[]).expect("a complete key");
        assert_eq!(key.columns, ["account_id", "owner"]);
        assert_eq!(key.ref_columns, ["id", "Owner"]);
        assert_eq!(
            (key.ref_schema.as_deref(), key.ref_table.as_str()),
            (Some("billing"), "accounts")
        );
    }

    #[test]
    fn fk_pairs_keep_source_order() {
        let columns = names(&["a", "b", "c"]);
        let referenced = names(&["c", "a"]);
        let mut draft = ForeignKeyDraft::default();

        draft.set_checked(&columns, "c", true, &referenced);
        draft.set_checked(&columns, "a", true, &referenced);
        draft.set_checked(&columns, "b", true, &referenced);
        draft.set_checked(&columns, "b", false, &referenced);

        assert_eq!(
            draft.pairs,
            [
                ("a".to_owned(), Some("a".to_owned())),
                ("c".to_owned(), Some("c".to_owned())),
            ]
        );
    }

    #[test]
    fn database_default_action_is_none() {
        let mut draft = ForeignKeyDraft {
            name: "fk".to_owned(),
            referenced: Some(TableRef::unqualified("parent")),
            ..ForeignKeyDraft::default()
        };
        draft.set_checked(&names(&["parent_id"]), "parent_id", true, &names(&["parent_id"]));
        draft.on_update = Some(ReferentialAction::Cascade);

        let key = draft.validate(&[]).expect("a complete key");

        assert_eq!(key.on_delete, None);
        assert_eq!(key.on_update, Some(ReferentialAction::Cascade));
    }
}
