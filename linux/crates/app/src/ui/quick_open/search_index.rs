use std::sync::Arc;
use tablepro_core::meta::{ObjectInfo, TableRef};

use super::matching;

pub(super) const LISTED: usize = 200;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Identity {
    Table(TableRef),
    Query(QueryId),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum QueryId {
    Saved(i64),
    Past(i64),
}

#[derive(Debug, Clone)]
pub(super) enum Candidate {
    Table(ObjectInfo),
    SavedQuery { id: i64, name: String },
    PastQuery { id: i64, name: String, sql: Arc<str> },
}

impl Candidate {
    pub(super) fn identity(&self) -> Identity {
        match self {
            Self::Table(object) => Identity::Table(TableRef::new(object.schema.clone(), object.name.clone())),
            Self::SavedQuery { id, .. } => Identity::Query(QueryId::Saved(*id)),
            Self::PastQuery { id, .. } => Identity::Query(QueryId::Past(*id)),
        }
    }

    pub(super) fn name(&self) -> &str {
        match self {
            Self::Table(object) => &object.name,
            Self::SavedQuery { name, .. } | Self::PastQuery { name, .. } => name,
        }
    }

    fn scope(&self) -> &str {
        match self {
            Self::Table(object) => object.schema.as_deref().unwrap_or_default(),
            Self::SavedQuery { .. } | Self::PastQuery { .. } => "",
        }
    }

    fn source_order(&self) -> u8 {
        match self {
            Self::Table(_) => 0,
            Self::SavedQuery { .. } => 1,
            Self::PastQuery { .. } => 2,
        }
    }

    fn id_order(&self) -> i64 {
        match self {
            Self::Table(_) => 0,
            Self::SavedQuery { id, .. } | Self::PastQuery { id, .. } => *id,
        }
    }
}

#[derive(Debug, Default)]
pub(super) struct SearchIndex {
    entries: Vec<(Candidate, Vec<char>, Vec<char>)>,
}

impl SearchIndex {
    pub(super) fn new(objects: &[ObjectInfo], queries: Vec<Candidate>) -> Self {
        let candidates = objects
            .iter()
            .filter(|object| object.kind.is_browsable())
            .cloned()
            .map(Candidate::Table)
            .chain(queries);
        let mut entries: Vec<_> = candidates
            .map(|candidate| {
                let name = matching::normalize(candidate.name());
                let qualified = if let Candidate::PastQuery { sql, .. } = &candidate {
                    matching::normalize(sql)
                } else {
                    matching::normalize(&if candidate.scope().is_empty() {
                        candidate.name().to_owned()
                    } else {
                        format!("{}.{}", candidate.scope(), candidate.name())
                    })
                };
                (candidate, name, qualified)
            })
            .collect();
        entries.sort_by(|(a, an, _), (b, bn, _)| {
            an.cmp(bn)
                .then_with(|| a.source_order().cmp(&b.source_order()))
                .then_with(|| a.scope().cmp(b.scope()))
                .then_with(|| a.name().cmp(b.name()))
                .then_with(|| a.id_order().cmp(&b.id_order()))
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
        let index = SearchIndex::new(
            &[
                object("public", "orders", ObjectKind::Table),
                object("sales", "orders", ObjectKind::View),
                object("sales", "order_items", ObjectKind::MaterializedView),
                object("sales", "ordered", ObjectKind::Function),
            ],
            vec![],
        );
        let names = |text| {
            index
                .search(text)
                .into_iter()
                .map(|c| c.name().to_owned())
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
        let index = SearchIndex::new(&objects, vec![]);
        assert_eq!(index.search("").len(), LISTED);
        assert_eq!(index.search("table_49999")[0].name(), "table_49999");
    }

    #[test]
    fn saved_queries_share_ranking_with_tables_and_have_stable_ties() {
        let index = SearchIndex::new(
            &[object("main", "orders", ObjectKind::Table)],
            vec![
                Candidate::SavedQuery {
                    id: 2,
                    name: "orders".into(),
                },
                Candidate::SavedQuery {
                    id: 1,
                    name: "orders".into(),
                },
                Candidate::SavedQuery {
                    id: 3,
                    name: "other".into(),
                },
            ],
        );
        let found = index.search("ord");
        assert_eq!(found.len(), 3);
        assert!(matches!(found[0], Candidate::Table(_)));
        assert_eq!(found[1].identity(), Identity::Query(QueryId::Saved(1)));
        assert_eq!(found[2].identity(), Identity::Query(QueryId::Saved(2)));
    }
    #[test]
    fn table_saved_and_past_queries_share_the_same_rank_and_source_ties() {
        let index = SearchIndex::new(
            &[object("main", "orders", ObjectKind::Table)],
            vec![
                Candidate::PastQuery {
                    id: 3,
                    name: "orders".into(),
                    sql: Arc::from("orders"),
                },
                Candidate::SavedQuery {
                    id: 2,
                    name: "orders".into(),
                },
            ],
        );
        let found = index.search("ord");
        assert!(matches!(found[0], Candidate::Table(_)));
        assert!(matches!(found[1], Candidate::SavedQuery { .. }));
        assert!(matches!(found[2], Candidate::PastQuery { .. }));
    }
}
