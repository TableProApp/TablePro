use std::collections::HashSet;

use crate::column::ResultColumn;

/// One JSON key per column, in column order. A join can return the
/// same column name twice (`SELECT a.id, b.id …`) and a JSON object
/// keyed by name alone would keep the last of them and drop the rest,
/// so a repeat is suffixed `_2`, `_3`, … until it is unique against
/// every name already taken, including the literal names of later
/// columns.
pub fn json_field_names(columns: &[ResultColumn]) -> Vec<String> {
    let mut reserved: HashSet<String> = columns.iter().map(|c| c.name.clone()).collect();
    let mut emitted: HashSet<String> = HashSet::with_capacity(columns.len());
    let mut names = Vec::with_capacity(columns.len());
    for col in columns {
        let mut name = col.name.clone();
        if !emitted.insert(name.clone()) {
            let mut suffix = 2;
            loop {
                let candidate = format!("{}_{suffix}", col.name);
                if !reserved.contains(&candidate) && emitted.insert(candidate.clone()) {
                    name = candidate;
                    break;
                }
                suffix += 1;
            }
            reserved.insert(name.clone());
        }
        names.push(name);
    }
    names
}

#[cfg(test)]
mod tests {
    use super::super::test_columns::cols;
    use super::*;

    #[test]
    fn a_repeated_name_is_numbered_rather_than_dropped() {
        let columns = cols(&["id", "name", "id"]);

        assert_eq!(json_field_names(&columns), vec!["id", "name", "id_2"]);
    }

    #[test]
    fn disambiguation_skips_a_name_a_real_column_already_holds() {
        let columns = cols(&["id", "id_2", "id"]);

        assert_eq!(json_field_names(&columns), vec!["id", "id_2", "id_3"]);
    }
}
