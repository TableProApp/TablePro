// A member the store holds at the value this build reads the base's copy as is no edit (0054, Dirty state is a diff).
// Another build can write the same value its own way: an iOS copy leaves out a tunnel the Mac writes switched off, a
// Mac writes an empty path the store keeps as none, and a newer build names a colour this one reads as none. The store
// can hold only its own reading, so such a member reads as the base's value: the push sends nothing over it, a merge
// takes no change from it, and the base's value stays until the person changes the member. A member the store holds at
// any other value is the device's edit.

use std::collections::BTreeSet;

use serde_json::Value;
use tablepro_records::Kind;
use uuid::Uuid;

use super::{connection, details, folders, groups, profiles};
use crate::adapters::fields::{get, members};
use crate::api::ids::ScopeName;

// What the store would hold of `base` as a wire record, or None for a kind the library does not hold.
fn read_back(kind: Kind, base: &Value) -> Option<Value> {
    let id = Uuid::nil();
    match kind {
        // Both namings of a driver write the name they read, so the Mac's stands for either.
        Kind::Connection => {
            let (saved, favorite) = connection::model(id, base, None, connection::DriverNames::Mac);
            Some(connection::to_wire(
                &saved,
                favorite,
                None,
                connection::DriverNames::Mac,
            ))
        }
        Kind::Group => Some(groups::group_to_wire(&groups::group(id, base, None))),
        Kind::Tag => Some(groups::tag_to_wire(&groups::tag(id, base, None))),
        Kind::SshProfile => Some(profiles::ssh_to_wire(&profiles::ssh(id, base, None))),
        Kind::CredentialProfile => Some(profiles::credential_to_wire(&profiles::credential(id, base, None))),
        Kind::TableFolder => folders::folder_from_wire(id, base).map(|folder| folders::folder_to_wire(&folder)),
        Kind::TableFolderItem => folders::item_from_wire(base).map(|item| folders::item_to_wire(&item)),
        _ => None,
    }
}

// A route another device published stays until a route that dials elsewhere replaces it: this device clears none and
// one that leads to the same hosts reads as the base's (`keepingForeignRoute`, `rebasedRoute`). Only its publisher
// clears a route on the Mac; the store does not know which device that is, so here none does.
fn route_at_base(kind: Kind, local: &Value, base: &Value) -> bool {
    let (Kind::Connection, Some(theirs)) = (kind, base.get("ssh_route")) else {
        return false;
    };
    local
        .get("ssh_route")
        .is_none_or(|mine| mine != theirs && details::same_hosts(mine, theirs))
}

// The members of `local` that read as the base's, by JSON Pointer.
pub fn at_base(kind: Kind, local: &Value, base: Option<&Value>) -> Vec<String> {
    let Some(base) = base else {
        return Vec::new();
    };
    let mut found = read_back_at_base(kind, local, base);
    if route_at_base(kind, local, base) {
        found.retain(|pointer| !pointer.starts_with("/ssh_route"));
        found.push("/ssh_route".to_owned());
    }
    found
}

fn read_back_at_base(kind: Kind, local: &Value, base: &Value) -> Vec<String> {
    let Some(read) = read_back(kind, base) else {
        return Vec::new();
    };
    if read == *base {
        return Vec::new();
    }
    let pointers: BTreeSet<String> = members(kind, ScopeName::Personal, Some(base), Some(&read))
        .into_iter()
        .chain(members(kind, ScopeName::Personal, Some(local), Some(&read)))
        .map(|member| member.pointer)
        .collect();
    pointers
        .into_iter()
        .filter(|pointer| {
            let held = get(Some(&read), pointer);
            get(Some(local), pointer) == held && get(Some(base), pointer) != held
        })
        .collect()
}
