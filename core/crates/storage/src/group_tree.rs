use std::collections::{HashMap, HashSet};

use uuid::Uuid;

use crate::ConnectionGroup;
use crate::error::StorageError;

/// The walks stop at a group they met before, so a list built by hand
/// with a cycle cannot hang one; the store never hands out such a list.
#[derive(Debug, Clone)]
pub struct GroupTree<'a> {
    groups: &'a [ConnectionGroup],
    at: HashMap<Uuid, usize>,
    children: HashMap<Option<Uuid>, Vec<usize>>,
}

impl<'a> GroupTree<'a> {
    pub const PATH_SEPARATOR: &'static str = " / ";

    pub fn new(groups: &'a [ConnectionGroup]) -> Self {
        let mut at = HashMap::with_capacity(groups.len());
        for (index, group) in groups.iter().enumerate() {
            at.entry(group.id).or_insert(index);
        }
        let mut children: HashMap<Option<Uuid>, Vec<usize>> = HashMap::new();
        for (index, group) in groups.iter().enumerate() {
            if at.get(&group.id) == Some(&index) {
                children.entry(group.parent_id).or_default().push(index);
            }
        }
        for siblings in children.values_mut() {
            siblings.sort_by_key(|index| (groups[*index].order, *index));
        }
        Self { groups, at, children }
    }

    pub fn get(&self, id: Uuid) -> Option<&'a ConnectionGroup> {
        self.at.get(&id).map(|index| &self.groups[*index])
    }

    pub fn contains(&self, id: Uuid) -> bool {
        self.at.contains_key(&id)
    }

    pub fn children(&self, parent: Option<Uuid>) -> Vec<&'a ConnectionGroup> {
        self.children
            .get(&parent)
            .map(|siblings| siblings.iter().map(|index| &self.groups[*index]).collect())
            .unwrap_or_default()
    }

    /// The top one first.
    pub fn path(&self, id: Uuid) -> Vec<&'a ConnectionGroup> {
        let mut path = Vec::new();
        let mut seen = HashSet::new();
        let mut current = Some(id);
        while let Some(group) = current.and_then(|id| self.get(id)) {
            if !seen.insert(group.id) {
                break;
            }
            path.push(group);
            current = group.parent_id;
        }
        path.reverse();
        path
    }

    pub fn label(&self, id: Uuid) -> Option<String> {
        let path = self.path(id);
        (!path.is_empty()).then(|| {
            path.iter()
                .map(|group| group.name.as_str())
                .collect::<Vec<_>>()
                .join(Self::PATH_SEPARATOR)
        })
    }

    /// 1 for a top-level group, 0 for the top itself.
    pub fn depth(&self, id: Option<Uuid>) -> usize {
        id.map_or(0, |id| self.path(id).len())
    }

    pub fn descendants(&self, id: Uuid) -> Vec<Uuid> {
        let mut found = Vec::new();
        let mut seen = HashSet::from([id]);
        let mut stack = vec![id];
        while let Some(parent) = stack.pop() {
            for child in self.children(Some(parent)) {
                if seen.insert(child.id) {
                    found.push(child.id);
                    stack.push(child.id);
                }
            }
        }
        found
    }

    /// 0 for a group with no subgroup.
    pub fn height(&self, id: Uuid) -> usize {
        let mut deepest = 0;
        let mut seen = HashSet::from([id]);
        let mut stack = vec![(id, 0)];
        while let Some((parent, depth)) = stack.pop() {
            deepest = deepest.max(depth);
            for child in self.children(Some(parent)) {
                if seen.insert(child.id) {
                    stack.push((child.id, depth + 1));
                }
            }
        }
        deepest
    }

    pub fn can_place(&self, group: Uuid, parent: Option<Uuid>) -> bool {
        self.check_place(Some(group), parent).is_ok()
    }

    pub fn can_create_in(&self, parent: Option<Uuid>) -> bool {
        self.check_place(None, parent).is_ok()
    }

    // `group` is `None` for a new group, which has no subgroup yet.
    pub(crate) fn check_place(&self, group: Option<Uuid>, parent: Option<Uuid>) -> Result<(), StorageError> {
        if let Some(id) = parent
            && !self.contains(id)
        {
            return Err(StorageError::GroupNotFound { id });
        }
        if let (Some(id), Some(target)) = (group, parent)
            && (target == id || self.descendants(id).contains(&target))
        {
            return Err(StorageError::GroupCycle { id });
        }
        let height = group.map_or(0, |id| self.height(id));
        if self.depth(parent) + 1 + height > ConnectionGroup::MAX_DEPTH {
            return Err(StorageError::GroupTooDeep {
                max: ConnectionGroup::MAX_DEPTH,
            });
        }
        Ok(())
    }

    /// The order a tree view lists them in: each group before its
    /// children.
    pub fn walk(&self) -> Vec<&'a ConnectionGroup> {
        let mut found = Vec::with_capacity(self.groups.len());
        let mut seen = HashSet::new();
        let mut stack: Vec<&ConnectionGroup> = self.children(None).into_iter().rev().collect();
        while let Some(group) = stack.pop() {
            if !seen.insert(group.id) {
                continue;
            }
            found.push(group);
            stack.extend(self.children(Some(group.id)).into_iter().rev());
        }
        found
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ConnectionGroupName;

    fn group(name: &str, parent: Option<&ConnectionGroup>, order: u32) -> ConnectionGroup {
        ConnectionGroup {
            order,
            ..ConnectionGroup::new(
                ConnectionGroupName::new(name).expect("a group name"),
                parent.map(|parent| parent.id),
            )
        }
    }

    fn names(groups: &[&ConnectionGroup]) -> Vec<String> {
        groups.iter().map(|group| group.name.as_str().to_owned()).collect()
    }

    #[test]
    fn a_tree_reads_paths_depths_and_children_in_order() {
        let work = group("Work", None, 1);
        let home = group("Home", None, 0);
        let staging = group("Staging", Some(&work), 1);
        let production = group("Production", Some(&work), 0);
        let eu = group("EU", Some(&staging), 0);
        let groups = vec![
            work.clone(),
            home.clone(),
            staging.clone(),
            production.clone(),
            eu.clone(),
        ];

        let tree = GroupTree::new(&groups);

        assert_eq!(names(&tree.children(None)), ["Home", "Work"]);
        assert_eq!(names(&tree.children(Some(work.id))), ["Production", "Staging"]);
        assert_eq!(names(&tree.path(eu.id)), ["Work", "Staging", "EU"]);
        assert_eq!(tree.label(eu.id).as_deref(), Some("Work / Staging / EU"));
        assert_eq!(tree.label(Uuid::new_v4()), None);
        assert_eq!(tree.depth(None), 0);
        assert_eq!(tree.depth(Some(home.id)), 1);
        assert_eq!(tree.depth(Some(eu.id)), 3);
        assert_eq!(tree.height(work.id), 2);
        assert_eq!(tree.height(home.id), 0);
        let mut below = tree.descendants(work.id);
        below.sort();
        let mut expected = vec![staging.id, production.id, eu.id];
        expected.sort();
        assert_eq!(below, expected);
        assert_eq!(names(&tree.walk()), ["Home", "Work", "Production", "Staging", "EU"]);
    }

    #[test]
    fn a_group_is_placed_only_under_an_existing_parent_outside_itself_within_three_levels() {
        let work = group("Work", None, 0);
        let staging = group("Staging", Some(&work), 0);
        let eu = group("EU", Some(&staging), 0);
        let home = group("Home", None, 1);
        let groups = vec![work.clone(), staging.clone(), eu.clone(), home.clone()];
        let tree = GroupTree::new(&groups);

        assert!(!tree.can_place(home.id, Some(eu.id)), "a leaf went under a third level");
        assert!(tree.can_place(home.id, Some(staging.id)));
        assert!(tree.can_place(staging.id, Some(home.id)));
        assert!(
            !tree.can_place(work.id, Some(home.id)),
            "a two-level subtree went under a group"
        );
        assert!(tree.can_place(work.id, None));
        assert!(tree.can_place(eu.id, None));
        assert!(!tree.can_place(work.id, Some(work.id)));
        assert!(!tree.can_place(work.id, Some(eu.id)));
        assert!(!tree.can_place(home.id, Some(Uuid::new_v4())));
        assert!(matches!(
            tree.check_place(Some(work.id), Some(staging.id)),
            Err(StorageError::GroupCycle { id }) if id == work.id
        ));
        assert!(matches!(
            tree.check_place(Some(home.id), Some(eu.id)),
            Err(StorageError::GroupTooDeep {
                max: ConnectionGroup::MAX_DEPTH
            })
        ));
    }

    #[test]
    fn a_new_group_fits_under_the_top_or_a_group_above_the_third_level() {
        let work = group("Work", None, 0);
        let staging = group("Staging", Some(&work), 0);
        let eu = group("EU", Some(&staging), 0);
        let groups = vec![work.clone(), staging.clone(), eu.clone()];
        let tree = GroupTree::new(&groups);

        assert!(tree.can_create_in(None));
        assert!(tree.can_create_in(Some(work.id)));
        assert!(tree.can_create_in(Some(staging.id)));
        assert!(!tree.can_create_in(Some(eu.id)));
        let missing = Uuid::new_v4();
        assert!(!tree.can_create_in(Some(missing)));
        assert!(matches!(
            tree.check_place(None, Some(missing)),
            Err(StorageError::GroupNotFound { id }) if id == missing
        ));
    }

    #[test]
    fn a_cycle_built_by_hand_does_not_hang_a_walk() {
        let mut first = group("First", None, 0);
        let second = group("Second", Some(&first), 0);
        first.parent_id = Some(second.id);
        let groups = vec![first.clone(), second.clone()];

        let tree = GroupTree::new(&groups);

        assert_eq!(names(&tree.path(first.id)), ["Second", "First"]);
        assert_eq!(tree.descendants(first.id), [second.id]);
        assert_eq!(tree.height(first.id), 1);
        assert!(tree.walk().is_empty(), "a cycle has no way in from the top");
    }
}
