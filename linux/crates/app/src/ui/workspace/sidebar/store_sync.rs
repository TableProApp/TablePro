use std::collections::{HashMap, HashSet};

use gtk4::gio;
use gtk4::glib;
use gtk4::prelude::*;

/// Make `store` hold `desired`, in order, each object once. The objects
/// that keep their order stay where they are, and only the others are
/// taken out and put back: a tree row taken out folds, so a store write
/// that changes one row leaves every other row open. Each change only
/// removes or only adds, so a list view never looks through added rows
/// for the rows it tracks.
pub(super) fn sync<T: IsA<glib::Object>>(store: &gio::ListStore, desired: &[T]) {
    let wanted: HashMap<glib::Object, usize> = desired
        .iter()
        .enumerate()
        .map(|(at, object)| (object.upcast_ref::<glib::Object>().clone(), at))
        .collect();
    let held: Vec<Option<usize>> = (0..store.n_items())
        .map(|at| store.item(at).and_then(|object| wanted.get(&object).copied()))
        .collect();
    let kept = longest_rising(&held);
    remove_runs(store, |at| !kept.contains(&at));
    // What is left is in the wanted order, so a wanted object that is not
    // next is missing, and goes in with the missing ones beside it.
    let mut position = 0;
    let mut pending: Vec<glib::Object> = Vec::new();
    for object in desired {
        let object = object.upcast_ref::<glib::Object>();
        if store.item(position).as_ref() != Some(object) {
            pending.push(object.clone());
            continue;
        }
        if !pending.is_empty() {
            store.splice(position, 0, &pending);
            position += u32::try_from(pending.len()).unwrap_or(u32::MAX);
            pending.clear();
        }
        position += 1;
    }
    if !pending.is_empty() {
        store.splice(position, 0, &pending);
    }
}

/// Take out every object at a position `gone` names, a run at a time
/// from the end, so each run is one change.
fn remove_runs(store: &gio::ListStore, gone: impl Fn(u32) -> bool) {
    let mut end = store.n_items();
    while end > 0 {
        if !gone(end - 1) {
            end -= 1;
            continue;
        }
        let mut start = end - 1;
        while start > 0 && gone(start - 1) {
            start -= 1;
        }
        store.splice(start, end - start, &[] as &[glib::Object]);
        end = start;
    }
}

/// The positions of the longest run of held objects whose wanted places
/// rise, the ones that can stay. An object not wanted is never kept.
fn longest_rising(held: &[Option<usize>]) -> HashSet<u32> {
    // tails[k] is the position whose wanted place ends the best rising
    // run of length k + 1 found so far.
    let mut tails: Vec<usize> = Vec::new();
    let mut before: Vec<Option<usize>> = vec![None; held.len()];
    for (at, place) in held.iter().enumerate() {
        let Some(place) = *place else {
            continue;
        };
        let length = tails.partition_point(|&tail| held[tail].is_some_and(|held| held < place));
        before[at] = length.checked_sub(1).map(|previous| tails[previous]);
        if length == tails.len() {
            tails.push(at);
        } else {
            tails[length] = at;
        }
    }
    let mut kept = HashSet::new();
    let mut current = tails.last().copied();
    while let Some(at) = current {
        kept.insert(u32::try_from(at).unwrap_or(u32::MAX));
        current = before[at];
    }
    kept
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use super::*;

    fn objects(count: usize) -> Vec<gtk4::StringObject> {
        (0..count).map(|at| gtk4::StringObject::new(&at.to_string())).collect()
    }

    fn store_of(items: &[gtk4::StringObject]) -> gio::ListStore {
        let store = gio::ListStore::new::<gtk4::StringObject>();
        store.extend_from_slice(items);
        store
    }

    fn held(store: &gio::ListStore) -> Vec<String> {
        (0..store.n_items())
            .filter_map(|at| store.item(at).and_downcast::<gtk4::StringObject>())
            .map(|object| object.string().to_string())
            .collect()
    }

    fn changes(store: &gio::ListStore) -> Rc<RefCell<Vec<(u32, u32, u32)>>> {
        let seen = Rc::new(RefCell::new(Vec::new()));
        let log = seen.clone();
        store.connect_items_changed(move |_, position, removed, added| {
            log.borrow_mut().push((position, removed, added));
        });
        seen
    }

    #[gtk4::test]
    fn one_object_moving_moves_only_that_object() {
        let all = objects(5);
        let store = store_of(&all);
        let seen = changes(&store);

        sync(
            &store,
            &[
                all[1].clone(),
                all[2].clone(),
                all[3].clone(),
                all[0].clone(),
                all[4].clone(),
            ],
        );

        assert_eq!(held(&store), ["1", "2", "3", "0", "4"]);
        assert_eq!(
            *seen.borrow(),
            [(0, 1, 0), (3, 0, 1)],
            "the rows that kept their order moved"
        );
    }

    #[gtk4::test]
    fn each_change_only_removes_or_only_adds() {
        let all = objects(6);
        let store = store_of(&all[..4]);
        let seen = changes(&store);

        sync(
            &store,
            &[all[4].clone(), all[0].clone(), all[3].clone(), all[5].clone()],
        );

        assert_eq!(held(&store), ["4", "0", "3", "5"]);
        assert!(
            seen.borrow()
                .iter()
                .all(|&(_, removed, added)| removed == 0 || added == 0),
            "{:?}",
            seen.borrow()
        );
        sync(
            &store,
            &[all[4].clone(), all[0].clone(), all[3].clone(), all[5].clone()],
        );
        assert_eq!(seen.borrow().len(), 3, "an unchanged store changed");
    }

    #[gtk4::test]
    fn an_emptied_store_and_a_filled_one_are_one_change_each() {
        let all = objects(3);
        let store = store_of(&all);
        let seen = changes(&store);

        sync(&store, &[] as &[gtk4::StringObject]);
        sync(&store, &all);

        assert_eq!(*seen.borrow(), [(0, 3, 0), (0, 0, 3)]);
    }
}
