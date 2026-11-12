use std::collections::{HashMap, HashSet};

use tablepro_storage::{ConnectionGroupName, SavedConnection};
use uuid::Uuid;

use super::{ImportReview, ImportSelection, Resolution};

// A name longer than the library keeps.
const MAX_NAME_CHARS: usize = 200;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlannedConnection {
    pub reference: String,
    pub connection: SavedConnection,
    pub group_path: Vec<ConnectionGroupName>,
    pub replaces: Option<Uuid>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum QueryTarget<'a> {
    // The connection this import writes for that row.
    Imported(&'a str),
    Existing(Uuid),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlannedQuery {
    pub reference: String,
    pub name: String,
    pub(super) target: PlannedTarget,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(super) enum PlannedTarget {
    Imported(String),
    Existing(Uuid),
}

impl PlannedQuery {
    pub fn target(&self) -> QueryTarget<'_> {
        match &self.target {
            PlannedTarget::Imported(reference) => QueryTarget::Imported(reference),
            PlannedTarget::Existing(id) => QueryTarget::Existing(*id),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QueryAvailability {
    Available,
    // The library keeps one query per name on a connection, and an earlier row of this import takes it.
    AddedByAnotherRow,
    TooLarge,
    NameTooLong,
    // Its connection is not imported, or its Replace went to another row.
    ConnectionSkipped,
    // The library keeps each query under one connection, and the other app filed this one under none.
    NoConnection,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QueryStatus {
    pub availability: QueryAvailability,
    pub included: bool,
}

impl QueryStatus {
    fn unavailable(availability: QueryAvailability) -> Self {
        Self {
            availability,
            included: false,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ImportPlan {
    connections: Vec<PlannedConnection>,
    kept: Vec<(String, Uuid)>,
    queries: Vec<PlannedQuery>,
    query_statuses: HashMap<String, QueryStatus>,
}

impl ImportPlan {
    pub fn is_empty(&self) -> bool {
        self.connections.is_empty() && self.queries.is_empty()
    }

    pub fn connections(&self) -> &[PlannedConnection] {
        &self.connections
    }

    // Rows that write nothing and lend their saved connection to their queries.
    pub fn kept_connections(&self) -> &[(String, Uuid)] {
        &self.kept
    }

    pub fn queries(&self) -> &[PlannedQuery] {
        &self.queries
    }

    pub fn query_statuses(&self) -> &HashMap<String, QueryStatus> {
        &self.query_statuses
    }

    pub fn query_status(&self, reference: &str) -> Option<QueryStatus> {
        self.query_statuses.get(reference).copied()
    }
}

pub fn plan(review: &ImportReview, selection: &ImportSelection) -> ImportPlan {
    let mut plan = ImportPlan::default();
    let targets = plan_connections(review, selection, &mut plan);
    plan_queries(review, selection, &targets, &mut plan);
    plan
}

fn plan_connections(
    review: &ImportReview,
    selection: &ImportSelection,
    plan: &mut ImportPlan,
) -> HashMap<String, PlannedTarget> {
    let mut targets = HashMap::new();
    let mut replaced = HashSet::new();
    for row in review.connections() {
        let (Some(resolution), Some(connection)) = (selection.resolution(&row.reference), &row.connection) else {
            continue;
        };
        let mut connection = connection.clone();
        let replaces = match resolution {
            Resolution::KeepExisting(id) => {
                plan.kept.push((row.reference.clone(), id));
                targets.insert(row.reference.clone(), PlannedTarget::Existing(id));
                continue;
            }
            Resolution::Add | Resolution::AddCopy => {
                targets.insert(row.reference.clone(), PlannedTarget::Imported(row.reference.clone()));
                None
            }
            Resolution::Replace(id) => {
                if !replaced.insert(id) {
                    continue;
                }
                // The write keeps the id, so a row keeping the same connection shares its query names.
                connection.id = id;
                targets.insert(row.reference.clone(), PlannedTarget::Existing(id));
                Some(id)
            }
        };
        plan.connections.push(PlannedConnection {
            reference: row.reference.clone(),
            connection,
            group_path: row
                .group_path
                .iter()
                .filter_map(|name| ConnectionGroupName::new(name).ok())
                .collect(),
            replaces,
        });
    }
    targets
}

fn plan_queries(
    review: &ImportReview,
    selection: &ImportSelection,
    targets: &HashMap<String, PlannedTarget>,
    plan: &mut ImportPlan,
) {
    let mut taken: HashSet<(PlannedTarget, String)> = HashSet::new();
    for row in review.saved_queries() {
        let status = match row.connection.as_ref().map(|connection| targets.get(connection)) {
            None => QueryStatus::unavailable(QueryAvailability::NoConnection),
            Some(None) => QueryStatus::unavailable(QueryAvailability::ConnectionSkipped),
            Some(Some(_)) if row.too_large || row.text.is_none() => {
                QueryStatus::unavailable(QueryAvailability::TooLarge)
            }
            Some(Some(_)) if row.name.chars().count() > MAX_NAME_CHARS => {
                QueryStatus::unavailable(QueryAvailability::NameTooLong)
            }
            Some(Some(target)) if taken.contains(&(target.clone(), row.name.clone())) => {
                QueryStatus::unavailable(QueryAvailability::AddedByAnotherRow)
            }
            Some(Some(target)) => {
                let included = selection.wants_query(row);
                if included {
                    taken.insert((target.clone(), row.name.clone()));
                    plan.queries.push(PlannedQuery {
                        reference: row.reference.clone(),
                        name: row.name.clone(),
                        target: target.clone(),
                    });
                }
                QueryStatus {
                    availability: QueryAvailability::Available,
                    included,
                }
            }
        };
        plan.query_statuses.insert(row.reference.clone(), status);
    }
}
