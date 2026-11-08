use tablepro_core::meta::{ObjectInfo, TableRef};

use super::matching;

pub(super) const LISTED: usize = 200;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Target {
    Table(TableRef),
}

#[derive(Debug, Clone)]
pub(super) struct Candidate {
    pub(super) object: ObjectInfo,
}

impl Candidate {
    pub(super) fn target(&self) -> Target {
        Target::Table(TableRef::new(self.object.schema.clone(), self.object.name.clone()))
    }
}

#[derive(Debug, Default)]
pub(super) struct SearchIndex {
    entries: Vec<(Candidate, Vec<char>, Vec<char>)>,
}

impl SearchIndex {
    pub(super) fn tables(objects: &[ObjectInfo]) -> Self {
        Self::new(
            objects
                .iter()
                .filter(|object| object.kind.is_browsable())
                .cloned()
                .map(|object| Candidate { object })
                .collect(),
        )
    }

    pub(super) fn new(candidates: Vec<Candidate>) -> Self {
        let mut entries: Vec<_> = candidates
            .into_iter()
            .map(|candidate| {
                let name = matching::normalize(&candidate.object.name);
                let qualified = matching::normalize(&match candidate.object.schema.as_deref() {
                    Some(schema) => format!("{schema}.{}", candidate.object.name),
                    None => candidate.object.name.clone(),
                });
                (candidate, name, qualified)
            })
            .collect();
        entries.sort_by(|(a, an, _), (b, bn, _)| {
            an.cmp(bn)
                .then_with(|| a.object.schema.cmp(&b.object.schema))
                .then_with(|| a.object.name.cmp(&b.object.name))
        });
        Self { entries }
    }

    pub(super) fn search(&self, typed: &str) -> Vec<Candidate> {
        let typed = matching::normalize(typed.trim());
        let mut found: Vec<_> = self
            .entries
            .iter()
            .filter_map(|(candidate, name, qualified)| {
                matching::rank(&typed, name)
                    .into_iter()
                    .chain(matching::rank(&typed, qualified))
                    .min()
                    .map(|rank| (rank, candidate))
            })
            .collect();
        found.sort_by_key(|(rank, _)| *rank);
        found
            .into_iter()
            .take(LISTED)
            .map(|(_, candidate)| candidate.clone())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::meta::ObjectKind;

    fn object(schema: &str, name: &str, kind: ObjectKind) -> ObjectInfo {
        ObjectInfo::new(Some(schema.to_owned()), name, kind)
    }

    #[test]
    fn browsable_objects_share_ranking_and_qualified_names() {
        let index = SearchIndex::tables(&[
            object("public", "orders", ObjectKind::Table),
            object("sales", "orders", ObjectKind::View),
            object("sales", "order_items", ObjectKind::MaterializedView),
            object("sales", "ordered", ObjectKind::Function),
        ]);
        let names = |text| {
            index
                .search(text)
                .into_iter()
                .map(|c| c.object.name)
                .collect::<Vec<_>>()
        };
        assert_eq!(names("ord"), ["order_items", "orders", "orders"]);
        assert_eq!(names("sales.orders"), ["orders"]);
        assert!(names("zzz").is_empty());
    }

    #[test]
    fn the_cap_applies_after_matching_the_entire_catalog() {
        let objects: Vec<_> = (0..50_000)
            .map(|i| object("main", &format!("table_{i:05}"), ObjectKind::Table))
            .collect();
        let index = SearchIndex::tables(&objects);
        assert_eq!(index.search("").len(), LISTED);
        assert_eq!(index.search("table_49999")[0].object.name, "table_49999");
    }
}
