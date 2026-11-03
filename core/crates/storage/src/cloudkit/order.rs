use std::cmp::Ordering;

use uuid::Uuid;

use super::values::{name_order, sort_key};

pub(super) struct Sibling<'a> {
    pub id: Uuid,
    pub name: &'a str,
    // The base record's raw `sortOrder`, when that record already places the item in this list.
    pub base: Option<Option<i64>>,
}

// Each sibling's `sortOrder`, given in the list's order. Values the server holds stay while they still read in
// this order, so a list nobody reordered writes nothing; otherwise the list is numbered from 0, as macOS numbers one.
pub(super) fn sort_orders(siblings: &[Sibling<'_>]) -> Vec<Option<i64>> {
    keeping_base(siblings).unwrap_or_else(|| {
        siblings
            .iter()
            .zip(0_i64..)
            .map(|(sibling, index)| match sibling.base {
                Some(raw) if sort_key(raw) == index => raw,
                _ => Some(index),
            })
            .collect()
    })
}

pub(super) fn reads_before(left: (i64, &str, Uuid), right: (i64, &str, Uuid)) -> Ordering {
    left.0
        .cmp(&right.0)
        .then_with(|| name_order((left.1, left.2), (right.1, right.2)))
}

fn keeping_base(siblings: &[Sibling<'_>]) -> Option<Vec<Option<i64>>> {
    let anchors: Vec<(usize, i64)> = siblings
        .iter()
        .enumerate()
        .filter_map(|(index, sibling)| sibling.base.map(|raw| (index, sort_key(raw))))
        .collect();
    let in_order = anchors.windows(2).all(|pair| {
        let (left, right) = (&siblings[pair[0].0], &siblings[pair[1].0]);
        reads_before((pair[0].1, left.name, left.id), (pair[1].1, right.name, right.id)).is_lt()
    });
    if !in_order {
        return None;
    }
    let mut orders: Vec<Option<i64>> = siblings.iter().map(|sibling| sibling.base.flatten()).collect();
    let mut start = 0;
    let mut previous: Option<i64> = None;
    for anchor in anchors.iter().map(Some).chain([None]) {
        let end = anchor.map_or(siblings.len(), |(index, _)| *index);
        let next = anchor.map(|(_, key)| *key);
        fill(&mut orders[start..end], previous, next)?;
        if let Some((index, key)) = anchor {
            start = index + 1;
            previous = Some(*key);
        }
    }
    Some(orders)
}

// Numbers a run of new siblings strictly between the keys around it, so each reads where it stands.
fn fill(run: &mut [Option<i64>], previous: Option<i64>, next: Option<i64>) -> Option<()> {
    let count = i64::try_from(run.len()).ok()?;
    if count == 0 {
        return Some(());
    }
    let first = match (previous, next) {
        (Some(previous), Some(next)) if next.checked_sub(previous)?.checked_sub(1)? >= count => previous + 1,
        (Some(_), Some(_)) => return None,
        (Some(previous), None) => previous.checked_add(1)?,
        (None, Some(next)) => next.checked_sub(count)?,
        (None, None) => 0,
    };
    for (slot, offset) in run.iter_mut().zip(0_i64..) {
        *slot = Some(first.checked_add(offset)?);
    }
    Some(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(count: usize) -> Vec<Uuid> {
        let mut ids: Vec<Uuid> = (0..count).map(|_| Uuid::new_v4()).collect();
        ids.sort();
        ids
    }

    fn siblings<'a>(ids: &[Uuid], names: &[&'a str], bases: &[Option<Option<i64>>]) -> Vec<Sibling<'a>> {
        ids.iter()
            .zip(names)
            .zip(bases)
            .map(|((id, name), base)| Sibling {
                id: *id,
                name,
                base: *base,
            })
            .collect()
    }

    #[test]
    fn a_list_in_the_order_its_records_read_keeps_every_value() {
        let ids = ids(3);
        let list = siblings(&ids, &["a", "b", "c"], &[Some(Some(0)), Some(Some(5)), Some(Some(7))]);

        assert_eq!(sort_orders(&list), [Some(0), Some(5), Some(7)]);
    }

    #[test]
    fn a_missing_order_and_a_tie_broken_by_name_are_kept() {
        let ids = ids(3);
        let list = siblings(&ids, &["a", "B", "c"], &[Some(None), Some(Some(0)), Some(Some(1))]);

        assert_eq!(sort_orders(&list), [None, Some(0), Some(1)]);
    }

    #[test]
    fn a_new_sibling_takes_a_free_value_between_its_neighbours_or_after_the_last() {
        let ids = ids(4);
        let between = siblings(&ids, &["a", "b", "c", "d"], &[Some(Some(0)), None, Some(Some(5)), None]);

        assert_eq!(sort_orders(&between), [Some(0), Some(1), Some(5), Some(6)]);

        let first = siblings(&ids[..2], &["a", "b"], &[None, Some(Some(0))]);

        assert_eq!(sort_orders(&first), [Some(-1), Some(0)]);
    }

    #[test]
    fn a_reordered_list_is_numbered_from_zero_writing_only_what_moved() {
        let ids = ids(3);
        let list = siblings(&ids, &["c", "a", "b"], &[Some(Some(2)), Some(Some(0)), Some(Some(1))]);

        assert_eq!(sort_orders(&list), [Some(0), Some(1), Some(2)]);

        let moved = siblings(&ids, &["a", "c", "b"], &[Some(Some(0)), Some(Some(2)), Some(Some(1))]);

        assert_eq!(sort_orders(&moved), [Some(0), Some(1), Some(2)]);
    }

    #[test]
    fn a_new_sibling_with_no_room_between_its_neighbours_renumbers_the_list() {
        let ids = ids(3);
        let list = siblings(&ids, &["a", "b", "c"], &[Some(Some(0)), None, Some(Some(1))]);

        assert_eq!(sort_orders(&list), [Some(0), Some(1), Some(2)]);
    }

    #[test]
    fn values_at_the_ends_of_the_range_never_overflow() {
        let ids = ids(2);
        let after = siblings(&ids, &["a", "b"], &[Some(Some(i64::MAX)), None]);
        let before = siblings(&ids, &["a", "b"], &[None, Some(Some(i64::MIN))]);

        assert_eq!(sort_orders(&after), [Some(0), Some(1)]);
        assert_eq!(sort_orders(&before), [Some(0), Some(1)]);
    }
}
