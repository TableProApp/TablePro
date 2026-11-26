// The cycle rule (0051, Conflict rules; 0010): a move that would close a cycle keeps the server's parent.

use std::collections::{HashMap, HashSet};
use std::hash::Hash;

// Every id on a cycle of parents.
pub fn cyclic<Id: Copy + Eq + Hash>(parents: &HashMap<Id, Option<Id>>) -> HashSet<Id> {
    let mut cyclic = HashSet::new();
    let mut settled = HashSet::new();
    for &start in parents.keys() {
        let mut path: Vec<Id> = Vec::new();
        let mut on_path: HashMap<Id, usize> = HashMap::new();
        let mut current = Some(start);
        while let Some(id) = current {
            if settled.contains(&id) || cyclic.contains(&id) {
                break;
            }
            if let Some(&at) = on_path.get(&id) {
                cyclic.extend(path[at..].iter().copied());
                break;
            }
            on_path.insert(id, path.len());
            path.push(id);
            current = parents.get(&id).copied().flatten();
        }
        settled.extend(path.into_iter().filter(|id| !cyclic.contains(id)));
    }
    cyclic
}

// Each record this device moved that now sits on a cycle takes the server's parent back, until no cycle is left.
// Returns the ids that yielded.
pub fn keep_server_parents<Id: Copy + Eq + Hash>(
    parents: &mut HashMap<Id, Option<Id>>,
    server: &HashMap<Id, Option<Id>>,
    moved_here: &HashSet<Id>,
) -> HashSet<Id> {
    let mut yielded = HashSet::new();
    loop {
        let mut changed = false;
        for id in cyclic(parents) {
            if !moved_here.contains(&id) {
                continue;
            }
            let theirs = server.get(&id).copied().flatten();
            if let Some(parent) = parents.get_mut(&id)
                && *parent != theirs
            {
                *parent = theirs;
                yielded.insert(id);
                changed = true;
            }
        }
        if !changed {
            return yielded;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_loop_and_a_self_parent_are_cycles_and_a_chain_is_not() {
        let parents = HashMap::from([
            (1, Some(2)),
            (2, Some(1)),
            (3, Some(3)),
            (4, Some(5)),
            (5, None),
            (6, Some(9)),
        ]);

        assert_eq!(cyclic(&parents), HashSet::from([1, 2, 3]));
    }

    #[test]
    fn two_crossing_moves_keep_the_servers_parent_for_this_devices_move() {
        // The server moved 1 under 2; this device moved 2 under 1.
        let mut parents = HashMap::from([(1, Some(2)), (2, Some(1))]);
        let server = HashMap::from([(1, Some(2)), (2, None)]);

        let yielded = keep_server_parents(&mut parents, &server, &HashSet::from([2]));

        assert_eq!(yielded, HashSet::from([2]));
        assert_eq!(parents, HashMap::from([(1, Some(2)), (2, None)]));
    }

    #[test]
    fn a_cycle_this_device_did_not_make_is_left_for_the_reader() {
        let mut parents = HashMap::from([(1, Some(2)), (2, Some(1))]);
        let server = parents.clone();

        assert!(keep_server_parents(&mut parents, &server, &HashSet::new()).is_empty());
        assert_eq!(cyclic(&parents), HashSet::from([1, 2]));
    }
}
