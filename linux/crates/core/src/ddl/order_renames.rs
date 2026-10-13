use std::collections::{HashMap, HashSet};

use super::ColumnRename;

const TEMPORARY_PREFIX: &str = "__tablepro_rename_";

/// The renames in an order that runs them one at a time, each into a
/// name that is free when it runs. A swap, or any longer cycle, has no
/// such order, so one column of it steps aside to a temporary
/// `__tablepro_rename_<n>` name first and takes its new name last.
///
/// `occupied` holds the columns the table has when the renames start,
/// the renamed ones included. `added` holds the columns added after
/// them, which a temporary name keeps clear of, as it does every name
/// the renames start from or end with.
///
/// A rename into a name a column keeps until after the renames cannot
/// be ordered, and is left for the server to refuse.
///
/// Names match without regard to case: MySQL, SQL Server and SQLite
/// compare column names that way, and the extra step this can cost a
/// case-sensitive engine changes nothing it ends with.
pub fn order_renames<'a>(
    renames: &[ColumnRename],
    occupied: impl IntoIterator<Item = &'a str>,
    added: impl IntoIterator<Item = &'a str>,
) -> Vec<ColumnRename> {
    let mut pending: Vec<ColumnRename> = renames
        .iter()
        .filter(|rename| rename.from != rename.to)
        .cloned()
        .collect();
    let mut held = Held::default();
    for name in occupied {
        held.insert(name);
    }
    for rename in &pending {
        if !held.contains(&rename.from) {
            held.insert(&rename.from);
        }
    }
    let mut reserved: HashSet<String> = held.counts.keys().cloned().collect();
    reserved.extend(added.into_iter().map(fold));
    reserved.extend(pending.iter().map(|rename| fold(&rename.to)));

    let mut ordered = Vec::with_capacity(pending.len());
    let mut next_temporary = 1usize;
    while !pending.is_empty() {
        if let Some(index) = pending.iter().position(|rename| is_free(&held, rename)) {
            let rename = pending.remove(index);
            held.remove(&rename.from);
            held.insert(&rename.to);
            ordered.push(rename);
            continue;
        }
        let Some(index) = cycle_member(&pending) else {
            ordered.append(&mut pending);
            break;
        };
        let temporary = loop {
            let name = format!("{TEMPORARY_PREFIX}{next_temporary}");
            next_temporary += 1;
            if reserved.insert(fold(&name)) {
                break name;
            }
        };
        let rename = &mut pending[index];
        held.remove(&rename.from);
        held.insert(&temporary);
        ordered.push(ColumnRename {
            from: std::mem::replace(&mut rename.from, temporary.clone()),
            to: temporary,
        });
    }
    ordered
}

/// A rename into its own name in other case frees what it takes.
fn is_free(held: &Held, rename: &ColumnRename) -> bool {
    same(&rename.from, &rename.to) || !held.contains(&rename.to)
}

/// A rename whose new name another pending rename starts from, and so on
/// back to it. Each name starts at most one rename, so following the
/// names either comes back or runs out.
fn cycle_member(pending: &[ColumnRename]) -> Option<usize> {
    let blocker = |index: usize| pending.iter().position(|other| same(&other.from, &pending[index].to));
    (0..pending.len()).find(|&start| {
        let mut current = start;
        for _ in 0..pending.len() {
            match blocker(current) {
                Some(next) if next == start => return true,
                Some(next) => current = next,
                None => return false,
            }
        }
        false
    })
}

fn fold(name: &str) -> String {
    name.to_lowercase()
}

fn same(left: &str, right: &str) -> bool {
    fold(left) == fold(right)
}

/// Column names in use, counted, since a case-sensitive engine can hold
/// two that fold to one.
#[derive(Default)]
struct Held {
    counts: HashMap<String, usize>,
}

impl Held {
    fn insert(&mut self, name: &str) {
        *self.counts.entry(fold(name)).or_default() += 1;
    }

    fn remove(&mut self, name: &str) {
        let key = fold(name);
        if let Some(count) = self.counts.get_mut(&key) {
            *count -= 1;
            if *count == 0 {
                self.counts.remove(&key);
            }
        }
    }

    fn contains(&self, name: &str) -> bool {
        self.counts.contains_key(&fold(name))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rename(from: &str, to: &str) -> ColumnRename {
        ColumnRename {
            from: from.to_owned(),
            to: to.to_owned(),
        }
    }

    fn steps(ordered: &[ColumnRename]) -> Vec<(&str, &str)> {
        ordered
            .iter()
            .map(|rename| (rename.from.as_str(), rename.to.as_str()))
            .collect()
    }

    #[test]
    fn order_renames_simple() {
        let ordered = order_renames(
            &[rename("email", "mail"), rename("name", "full_name")],
            ["id", "email", "name"],
            [],
        );

        assert_eq!(steps(&ordered), [("email", "mail"), ("name", "full_name")]);
    }

    #[test]
    fn order_renames_runs_a_chain_from_its_free_end() {
        let ordered = order_renames(&[rename("a", "b"), rename("b", "c")], ["a", "b"], []);

        assert_eq!(steps(&ordered), [("b", "c"), ("a", "b")]);
    }

    #[test]
    fn order_renames_swap_uses_temporary_name() {
        let ordered = order_renames(&[rename("a", "b"), rename("b", "a")], ["id", "a", "b"], []);

        assert_eq!(
            steps(&ordered),
            [("a", "__tablepro_rename_1"), ("b", "a"), ("__tablepro_rename_1", "b")]
        );
    }

    #[test]
    fn order_renames_breaks_a_three_way_cycle_once() {
        let ordered = order_renames(
            &[rename("a", "b"), rename("b", "c"), rename("c", "a")],
            ["a", "b", "c"],
            [],
        );

        assert_eq!(
            steps(&ordered),
            [
                ("a", "__tablepro_rename_1"),
                ("c", "a"),
                ("b", "c"),
                ("__tablepro_rename_1", "b"),
            ]
        );
    }

    #[test]
    fn order_renames_avoids_added_column_name() {
        let ordered = order_renames(
            &[rename("a", "b"), rename("b", "a")],
            ["a", "b", "__tablepro_rename_1"],
            ["__TablePro_Rename_2"],
        );

        assert_eq!(
            steps(&ordered),
            [("a", "__tablepro_rename_3"), ("b", "a"), ("__tablepro_rename_3", "b")]
        );
    }

    #[test]
    fn order_renames_matches_names_without_case() {
        let case_only = order_renames(&[rename("Email", "email")], ["id", "Email"], []);
        let swapped = order_renames(&[rename("a", "B"), rename("b", "A")], ["a", "b"], []);

        assert_eq!(steps(&case_only), [("Email", "email")]);
        assert_eq!(
            steps(&swapped),
            [("a", "__tablepro_rename_1"), ("b", "A"), ("__tablepro_rename_1", "B")]
        );
    }

    #[test]
    fn order_renames_leaves_a_name_still_held_to_the_server() {
        let ordered = order_renames(&[rename("a", "b"), rename("c", "d")], ["a", "b", "c"], []);

        assert_eq!(steps(&ordered), [("c", "d"), ("a", "b")]);
    }
}
