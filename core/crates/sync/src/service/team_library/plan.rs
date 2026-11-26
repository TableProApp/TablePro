// The publish plan the Swift app had (`TeamLibraryPublishPlan`), over the team as this device holds it: the store's
// copy, which already carries the edits still to go up, the bases for what the team deleted, and what only this device
// knows. An item the team holds as it would be sent is left out, so publishing twice writes nothing the second time.
#![expect(
    clippy::disallowed_types,
    reason = "record fields compare as JSON values, as Postgres jsonb does, so member order carries nothing"
)]

use std::collections::{BTreeSet, HashMap, HashSet};

use serde_json::{Map, Value};
use tablepro_records::record_id::{library_id, library_ids_match};
use tablepro_records::schema::schema;
use tablepro_records::secret_key::is_secret_key;
use tablepro_storage::{TeamLibraryItem, TeamLibraryKind, TeamLibraryLocal};
use uuid::Uuid;

use crate::api::state::BaseRow;
use crate::api::team_library::{TeamConnection, TeamFolder, TeamItemRef, TeamQuery};
use crate::api::transport::DeletedReason;

pub(super) fn kind_of(kind: TeamLibraryKind) -> tablepro_records::Kind {
    match kind {
        TeamLibraryKind::Connection => tablepro_records::Kind::LibraryConnection,
        TeamLibraryKind::Folder => tablepro_records::Kind::LibraryFolder,
        TeamLibraryKind::Query => tablepro_records::Kind::LibraryQuery,
    }
}

// The team as the plan reads it.
pub(super) struct TeamView<'a> {
    pub(super) items: &'a [TeamLibraryItem],
    pub(super) bases: &'a [(TeamLibraryKind, BaseRow)],
    pub(super) local: &'a TeamLibraryLocal,
    collided: HashSet<(TeamLibraryKind, String)>,
}

// The ids two records of one kind share once lower-cased, tombstones included. Neither record is planned, removed or
// referred to, since picking one would let an edit or a tombstone land on the other (0052, Team scope).
pub(super) fn collisions<'a>(
    ids: impl IntoIterator<Item = (TeamLibraryKind, &'a str)>,
) -> HashSet<(TeamLibraryKind, String)> {
    let mut spellings: HashMap<(TeamLibraryKind, String), &str> = HashMap::new();
    let mut collided = HashSet::new();
    for (kind, id) in ids {
        let key = (kind, id.to_lowercase());
        match spellings.get(&key) {
            Some(held) if *held != id => {
                collided.insert(key);
            }
            Some(_) => {}
            None => {
                spellings.insert(key, id);
            }
        }
    }
    collided
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Planned {
    // `own` marks an item this device holds, which becomes its to remove once the team takes it; a move of someone
    // else's item is not.
    Put {
        kind: TeamLibraryKind,
        id: String,
        fields: Value,
        own: bool,
    },
    // The team deleted it: Keep Mine brings it back, Keep Theirs leaves it deleted (0051, Conflict rules).
    Ask {
        kind: TeamLibraryKind,
        id: String,
        fields: Value,
        own: bool,
    },
    Delete {
        kind: TeamLibraryKind,
        id: String,
    },
}

impl Planned {
    pub(super) fn item(&self) -> TeamItemRef {
        let (Self::Put { kind, id, .. } | Self::Ask { kind, id, .. } | Self::Delete { kind, id }) = self;
        TeamItemRef {
            kind: *kind,
            id: id.clone(),
        }
    }
}

// An item whose own id, or a folder or connection it names, collides.
pub(super) fn tangled(
    collided: &HashSet<(TeamLibraryKind, String)>,
    kind: TeamLibraryKind,
    id: &str,
    fields: Option<&Value>,
) -> bool {
    let collides = |kind: TeamLibraryKind, id: &str| collided.contains(&(kind, id.to_lowercase()));
    collides(kind, id)
        || [
            ("parent_client_id", TeamLibraryKind::Folder),
            ("folder_client_id", TeamLibraryKind::Folder),
            ("connection_client_id", TeamLibraryKind::Connection),
        ]
        .into_iter()
        .any(|(member, of)| {
            fields
                .and_then(|fields| text(fields, member))
                .is_some_and(|named| collides(of, named))
        })
}

impl<'a> TeamView<'a> {
    pub(super) fn new(
        items: &'a [TeamLibraryItem],
        bases: &'a [(TeamLibraryKind, BaseRow)],
        local: &'a TeamLibraryLocal,
    ) -> Self {
        let collided = collisions(
            items
                .iter()
                .map(|item| (item.kind, item.id.as_str()))
                .chain(bases.iter().map(|(kind, base)| (*kind, base.key.record_id.as_str()))),
        );
        Self {
            items,
            bases,
            local,
            collided,
        }
    }

    fn collides(&self, kind: TeamLibraryKind, id: &str) -> bool {
        self.collided.contains(&(kind, id.to_lowercase()))
    }

    fn tangled(&self, kind: TeamLibraryKind, id: &str, fields: &Value) -> bool {
        tangled(&self.collided, kind, id, Some(fields))
    }

    fn held(&self, kind: TeamLibraryKind, id: &str) -> Option<&TeamLibraryItem> {
        self.items
            .iter()
            .find(|item| item.kind == kind && library_ids_match(&item.id, id))
    }

    fn base(&self, kind: TeamLibraryKind, id: &str) -> Option<&BaseRow> {
        self.bases
            .iter()
            .find(|(held, base)| *held == kind && library_ids_match(&base.key.record_id, id))
            .map(|(_, base)| base)
    }

    // The id the team stores for this entity, live or deleted, else its UUID in lower case (0052, Team scope).
    fn stored_id(&self, kind: TeamLibraryKind, entity: Uuid) -> String {
        let items = self
            .items
            .iter()
            .filter(|item| item.kind == kind)
            .map(|item| item.id.as_str());
        let bases = self
            .bases
            .iter()
            .filter(|(held, _)| *held == kind)
            .map(|(_, base)| base.key.record_id.as_str());
        library_id(entity, items.chain(bases))
    }

    fn declines(&self, kind: TeamLibraryKind, id: &str, fields: &Value) -> bool {
        self.local
            .declined
            .iter()
            .any(|copy| copy.kind == kind && library_ids_match(&copy.id, id) && same_item(kind, &copy.fields, fields))
    }

    fn upsert(&self, kind: TeamLibraryKind, id: String, fields: Value, own: bool) -> Planned {
        let held = self.held(kind, &id);
        let deleted = self
            .base(kind, &id)
            .is_some_and(|base| base.deleted == Some(DeletedReason::User));
        match held {
            None if deleted => Planned::Ask { kind, id, fields, own },
            _ => Planned::Put {
                kind,
                fields: with_unknown_members(kind, held.map(|held| &held.fields), fields),
                id,
                own,
            },
        }
    }
}

// The members of the team's copy this build has no place for stay, as the facade keeps every key it does not carry.
pub(super) fn with_unknown_members(kind: TeamLibraryKind, held: Option<&Value>, fields: Value) -> Value {
    let (Some(Value::Object(held)), Value::Object(mut fields)) = (held, fields.clone()) else {
        return fields;
    };
    let known = schema(kind_of(kind));
    for (name, value) in held {
        if known.field(name).is_none() && !fields.contains_key(name) {
            fields.insert(name.clone(), value.clone());
        }
    }
    Value::Object(fields)
}

// The server refuses a whole push when a key at any depth names a secret (0051, What syncs).
pub(super) fn without_secret_keys(value: Value) -> Value {
    match value {
        Value::Object(members) => Value::Object(
            members
                .into_iter()
                .filter(|(name, _)| !is_secret_key(name))
                .map(|(name, member)| (name, without_secret_keys(member)))
                .collect(),
        ),
        Value::Array(items) => Value::Array(items.into_iter().map(without_secret_keys).collect()),
        other => other,
    }
}

fn text<'a>(fields: &'a Value, name: &str) -> Option<&'a str> {
    fields.get(name).and_then(Value::as_str).filter(|text| !text.is_empty())
}

fn number(fields: &Value, name: &str) -> i64 {
    fields.get(name).and_then(Value::as_i64).unwrap_or(0)
}

fn same_reference(left: Option<&str>, right: Option<&str>) -> bool {
    match (left, right) {
        (None, None) => true,
        (Some(left), Some(right)) => library_ids_match(left, right),
        _ => false,
    }
}

// `TeamLibraryFolderData.matches` and `TeamLibraryQueryData.matches`: names and text as written, references without
// case, and an empty keyword or reference as none.
pub(super) fn same_item(kind: TeamLibraryKind, held: &Value, sent: &Value) -> bool {
    let name = |fields: &Value| fields.get("name").and_then(Value::as_str).unwrap_or("").to_owned();
    let same_text = |member: &str| text(held, member) == text(sent, member);
    let same_ref = |member: &str| same_reference(text(held, member), text(sent, member));
    match kind {
        TeamLibraryKind::Folder => {
            name(held) == name(sent)
                && number(held, "sort_order") == number(sent, "sort_order")
                && same_ref("parent_client_id")
        }
        TeamLibraryKind::Query => {
            name(held) == name(sent)
                && held.get("query").and_then(Value::as_str).unwrap_or("")
                    == sent.get("query").and_then(Value::as_str).unwrap_or("")
                && number(held, "sort_order") == number(sent, "sort_order")
                && same_text("keyword")
                && same_ref("folder_client_id")
                && same_ref("connection_client_id")
        }
        TeamLibraryKind::Connection => with_unknown_members(kind, Some(held), sent.clone()) == *held,
    }
}

fn lower(id: Uuid) -> String {
    id.hyphenated().to_string()
}

pub(super) fn connections(view: &TeamView<'_>, connections: &[TeamConnection]) -> Vec<Planned> {
    let mut planned = Vec::new();
    for connection in connections {
        let kind = TeamLibraryKind::Connection;
        let id = view.stored_id(kind, connection.id);
        let fields = without_secret_keys(connection.settings.clone());
        if view.collides(kind, &id) {
            continue;
        }
        if view
            .held(kind, &id)
            .is_some_and(|held| same_item(kind, &held.fields, &fields))
        {
            continue;
        }
        if view.declines(kind, &id, &fields) {
            continue;
        }
        planned.push(view.upsert(kind, id, fields, true));
    }
    planned
}

fn object(members: Vec<(&str, Value)>) -> Value {
    Value::Object(
        members
            .into_iter()
            .map(|(name, value)| (name.to_owned(), value))
            .collect::<Map<String, Value>>(),
    )
}

fn folder_fields(view: &TeamView<'_>, folder: &TeamFolder, held: &HashSet<Uuid>) -> Value {
    let mut members = vec![
        ("name", Value::from(folder.name.clone())),
        ("sort_order", Value::from(folder.sort_order)),
    ];
    if let Some(parent) = folder.parent.filter(|parent| held.contains(parent)) {
        members.push((
            "parent_client_id",
            Value::from(view.stored_id(TeamLibraryKind::Folder, parent)),
        ));
    }
    object(members)
}

fn query_fields(view: &TeamView<'_>, query: &TeamQuery, folders: &HashSet<Uuid>) -> Value {
    let mut members = vec![
        ("name", Value::from(query.name.clone())),
        ("query", Value::from(query.query.clone())),
        ("sort_order", Value::from(query.sort_order)),
    ];
    if let Some(keyword) = query.keyword.as_ref().filter(|keyword| !keyword.is_empty()) {
        members.push(("keyword", Value::from(keyword.clone())));
    }
    if let Some(folder) = query.folder.filter(|folder| folders.contains(folder)) {
        members.push((
            "folder_client_id",
            Value::from(view.stored_id(TeamLibraryKind::Folder, folder)),
        ));
    }
    if let Some(connection) = query.connection {
        members.push(("connection_client_id", Value::from(lower(connection))));
    }
    object(members)
}

// A folder goes after its parent, so the team never holds one under a folder it has not seen yet.
fn parents_first(folders: &[TeamFolder]) -> Vec<&TeamFolder> {
    let mut sorted: Vec<&TeamFolder> = folders.iter().collect();
    sorted.sort_by_key(|folder| folder.sort_order);
    let mut ordered: Vec<&TeamFolder> = Vec::new();
    let mut placed: HashSet<Uuid> = HashSet::new();
    for folder in sorted.iter().copied() {
        place(folder, &sorted, 0, &mut placed, &mut ordered);
    }
    ordered
}

fn place<'a>(
    folder: &'a TeamFolder,
    all: &[&'a TeamFolder],
    depth: usize,
    placed: &mut HashSet<Uuid>,
    ordered: &mut Vec<&'a TeamFolder>,
) {
    if placed.contains(&folder.id) || depth >= all.len() {
        return;
    }
    if let Some(parent) = folder
        .parent
        .and_then(|parent| all.iter().copied().find(|held| held.id == parent))
    {
        place(parent, all, depth + 1, placed, ordered);
    }
    if placed.insert(folder.id) {
        ordered.push(folder);
    }
}

// Every saved query and folder this device holds goes up; the ones it published and no longer holds are removed, and
// what other people keep in a removed folder moves up to its parent first, since a folder delete moves nothing itself.
pub(super) fn saved_queries(view: &TeamView<'_>, folders: &[TeamFolder], queries: &[TeamQuery]) -> Vec<Planned> {
    let folder_ids: HashSet<Uuid> = folders.iter().map(|folder| folder.id).collect();
    let mut touched: HashSet<(TeamLibraryKind, String)> = HashSet::new();
    let mut planned = Vec::new();
    let mut push = |kind: TeamLibraryKind, id: String, fields: Value, planned: &mut Vec<Planned>| {
        touched.insert((kind, id.to_lowercase()));
        if view.tangled(kind, &id, &fields) {
            return;
        }
        let unchanged = view
            .held(kind, &id)
            .is_some_and(|held| same_item(kind, &held.fields, &fields));
        if !unchanged && !view.declines(kind, &id, &fields) {
            planned.push(view.upsert(kind, id, fields, true));
        }
    };
    for folder in parents_first(folders) {
        let id = view.stored_id(TeamLibraryKind::Folder, folder.id);
        push(
            TeamLibraryKind::Folder,
            id,
            folder_fields(view, folder, &folder_ids),
            &mut planned,
        );
    }
    for query in queries {
        let id = view.stored_id(TeamLibraryKind::Query, query.id);
        push(
            TeamLibraryKind::Query,
            id,
            query_fields(view, query, &folder_ids),
            &mut planned,
        );
    }
    let local: HashSet<(TeamLibraryKind, String)> = folders
        .iter()
        .map(|folder| (TeamLibraryKind::Folder, lower(folder.id)))
        .chain(queries.iter().map(|query| (TeamLibraryKind::Query, lower(query.id))))
        .collect();
    let removed = removed(view, &local);
    planned.extend(moves(view, &touched, &removed));
    planned.extend(deletions(removed));
    planned
}

// What this device published that the team still holds and this device no longer has.
fn removed(view: &TeamView<'_>, local: &HashSet<(TeamLibraryKind, String)>) -> Vec<TeamItemRef> {
    let mut removed: Vec<TeamItemRef> = Vec::new();
    let held = view
        .local
        .published
        .iter()
        .filter(|published| published.kind != TeamLibraryKind::Connection)
        .filter(|published| !view.collides(published.kind, &published.id))
        .filter_map(|published| view.held(published.kind, &published.id))
        .filter(|held| !view.tangled(held.kind, &held.id, &held.fields))
        .filter(|held| !local.contains(&(held.kind, held.id.to_lowercase())));
    for item in held {
        let item = TeamItemRef {
            kind: item.kind,
            id: item.id.clone(),
        };
        if !removed.contains(&item) {
            removed.push(item);
        }
    }
    removed
}

fn container(item: &TeamLibraryItem) -> Option<(&'static str, String)> {
    let member = match item.kind {
        TeamLibraryKind::Folder => "parent_client_id",
        TeamLibraryKind::Query => "folder_client_id",
        TeamLibraryKind::Connection => return None,
    };
    text(&item.fields, member).map(|id| (member, id.to_lowercase()))
}

fn moves(view: &TeamView<'_>, touched: &HashSet<(TeamLibraryKind, String)>, removed: &[TeamItemRef]) -> Vec<Planned> {
    let gone: BTreeSet<String> = removed
        .iter()
        .filter(|item| item.kind == TeamLibraryKind::Folder)
        .map(|item| item.id.to_lowercase())
        .collect();
    let mut items: Vec<&TeamLibraryItem> = view.items.iter().collect();
    items.sort_by(|left, right| left.id.cmp(&right.id));
    let mut planned = Vec::new();
    for item in items {
        let key = (item.kind, item.id.to_lowercase());
        let is_removed = removed
            .iter()
            .any(|gone| gone.kind == item.kind && library_ids_match(&gone.id, &item.id));
        let Some((member, folder)) = container(item) else {
            continue;
        };
        if touched.contains(&key)
            || is_removed
            || !gone.contains(&folder)
            || view.tangled(item.kind, &item.id, &item.fields)
        {
            continue;
        }
        let Some(parent) = surviving_parent(view, &folder, &gone) else {
            continue;
        };
        let mut fields = item.fields.clone();
        if let Value::Object(members) = &mut fields {
            match parent {
                Some(parent) => {
                    members.insert(member.to_owned(), Value::from(parent));
                }
                None => {
                    members.remove(member);
                }
            }
        }
        planned.push(view.upsert(item.kind, item.id.clone(), fields, false));
    }
    planned
}

// The first folder up the chain that stays, or Some(None) for the top. None when a folder on the way collides, so the
// item stays where it is.
fn surviving_parent(view: &TeamView<'_>, folder: &str, gone: &BTreeSet<String>) -> Option<Option<String>> {
    let mut current = Some(folder.to_owned());
    let mut seen = HashSet::new();
    while let Some(id) = current.clone() {
        if view.collides(TeamLibraryKind::Folder, &id) {
            return None;
        }
        if !gone.contains(&id) || !seen.insert(id.clone()) {
            break;
        }
        current = view
            .held(TeamLibraryKind::Folder, &id)
            .and_then(|held| text(&held.fields, "parent_client_id"))
            .map(str::to_lowercase);
    }
    let Some(id) = current.filter(|id| !gone.contains(id)) else {
        return Some(None);
    };
    Some(Some(
        view.held(TeamLibraryKind::Folder, &id)
            .map_or(id, |held| held.id.clone()),
    ))
}

// Queries before folders, as the Swift plan sorted them.
fn deletions(mut removed: Vec<TeamItemRef>) -> Vec<Planned> {
    let name = |kind: TeamLibraryKind| match kind {
        TeamLibraryKind::Connection => "connection",
        TeamLibraryKind::Folder => "folder",
        TeamLibraryKind::Query => "query",
    };
    removed.sort_by_key(|item| std::cmp::Reverse((name(item.kind), item.id.to_lowercase())));
    removed
        .into_iter()
        .map(|item| Planned::Delete {
            kind: item.kind,
            id: item.id,
        })
        .collect()
}

// The named items the team holds, in the spelling it stores.
pub(super) fn removals(view: &TeamView<'_>, items: &[TeamItemRef]) -> Vec<Planned> {
    let mut planned: Vec<Planned> = Vec::new();
    for item in items {
        if view.collides(item.kind, &item.id) {
            continue;
        }
        let Some(held) = view
            .held(item.kind, &item.id)
            .filter(|held| !view.tangled(held.kind, &held.id, &held.fields))
        else {
            continue;
        };
        let delete = Planned::Delete {
            kind: held.kind,
            id: held.id.clone(),
        };
        if !planned.contains(&delete) {
            planned.push(delete);
        }
    }
    planned
}

#[cfg(test)]
#[path = "plan_tests.rs"]
mod tests;
