use tablepro_core::browse::ReferenceError;

use crate::i18n::{gettext, gettext_f};

/// Why a foreign key could not be followed from a row, as a toast says
/// it.
pub fn reference_message(error: &ReferenceError) -> String {
    match error {
        ReferenceError::NullKey => gettext("The key is empty in this row"),
        ReferenceError::MissingColumn { column } => gettext_f("This row has no column {column}", &[("column", column)]),
        ReferenceError::UnevenKey { key } => gettext_f("Can't read the columns of the key {key}", &[("key", key)]),
        ReferenceError::UnknownSchema { table } => {
            gettext_f("Can't tell which schema {table} is in", &[("table", table)])
        }
        ReferenceError::NoFilterText { column } => {
            gettext_f("Can't filter {column} on this value", &[("column", column)])
        }
        ReferenceError::ComparedOtherwise { table } => gettext_f(
            "Can't filter {table} the way its key compares values",
            &[("table", table)],
        ),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    #[test]
    fn each_reason_reads_differently_and_names_what_it_is_about() {
        let errors = [
            ReferenceError::NullKey,
            ReferenceError::MissingColumn {
                column: "owner_id".to_owned(),
            },
            ReferenceError::UnevenKey {
                key: "fk_notes_0".to_owned(),
            },
            ReferenceError::UnknownSchema {
                table: "customers".to_owned(),
            },
            ReferenceError::NoFilterText {
                column: "outline".to_owned(),
            },
            ReferenceError::ComparedOtherwise {
                table: "orders".to_owned(),
            },
        ];

        let messages: Vec<String> = errors.iter().map(reference_message).collect();

        let distinct: HashSet<&String> = messages.iter().collect();
        assert_eq!(distinct.len(), messages.len(), "{messages:?}");
        assert!(messages[1].contains("owner_id"), "{messages:?}");
        assert!(messages[2].contains("fk_notes_0"), "{messages:?}");
        assert!(messages[3].contains("customers"), "{messages:?}");
        assert!(messages[4].contains("outline"), "{messages:?}");
        assert!(messages[5].contains("orders"), "{messages:?}");
    }
}
