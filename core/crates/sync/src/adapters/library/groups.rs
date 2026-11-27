// Groups, tags and projects as the Mac's mapper writes them (`SyncRecordMapper`, Connection Group, Connection Tag and
// Project): a group's or a project's colour is always named, "None" for none, and its icon, parent and project only
// when it has one; a tag's colour is always named, and one with none or one this build does not know reads as Gray, as
// the Mac reads it.

use serde_json::Value;
use tablepro_records::cloudkit::library::{color_name, color_named, icon_for_symbol, symbol_for_icon};
use tablepro_storage::{
    ConnectionColor, ConnectionGroup, ConnectionGroupName, ConnectionProject, ConnectionProjectName, ConnectionTag,
    ConnectionTagName,
};
use uuid::Uuid;

use super::values::{Object, boolean, clamped, integer, text, uuid_at, uuid_value};

pub(super) fn group_to_wire(group: &ConnectionGroup) -> Value {
    Object::default()
        .put("name", group.name.as_str())
        .put("color", color_name(group.color))
        .put_some("icon_name", group.icon.as_ref().and_then(symbol_for_icon))
        .put_some("parent_id", group.parent_id.map(uuid_value))
        .put_some("project_id", group.project_id.map(uuid_value))
        .put("sort_order", group.order)
        .done()
}

// A member the record lacks keeps what the store holds, as a name no build would empty.
pub(super) fn group(id: Uuid, fields: &Value, stored: Option<&ConnectionGroup>) -> ConnectionGroup {
    let name = text(fields, "name")
        .map(ConnectionGroupName::from_stored)
        .or_else(|| stored.map(|stored| stored.name.clone()))
        .unwrap_or_else(|| ConnectionGroupName::from_stored(""));
    ConnectionGroup {
        id,
        name,
        parent_id: uuid_at(fields, "parent_id"),
        project_id: uuid_at(fields, "project_id"),
        order: integer(fields, "sort_order").map_or(0, clamped),
        color: text(fields, "color").and_then(color_named),
        icon: text(fields, "icon_name").and_then(icon_for_symbol),
    }
}

pub(super) fn project_to_wire(project: &ConnectionProject) -> Value {
    Object::default()
        .put("name", project.name.as_str())
        .put("color", color_name(project.color))
        .put_some("icon_name", project.icon.as_ref().and_then(symbol_for_icon))
        .put("sort_order", project.order)
        .done()
}

// None for a record with no name the store can hold and no stored project to keep the name of: a name is required.
pub(super) fn project(id: Uuid, fields: &Value, stored: Option<&ConnectionProject>) -> Option<ConnectionProject> {
    let name = text(fields, "name")
        .and_then(|name| ConnectionProjectName::from_stored(name).ok())
        .or_else(|| stored.map(|stored| stored.name.clone()))?;
    Some(ConnectionProject {
        id,
        name,
        order: integer(fields, "sort_order").map_or(0, clamped),
        color: text(fields, "color").and_then(color_named),
        icon: text(fields, "icon_name").and_then(icon_for_symbol),
    })
}

pub(super) fn tag_to_wire(tag: &ConnectionTag) -> Value {
    Object::default()
        .put("name", tag.name.as_str())
        .put("color", color_name(tag.color))
        .put("is_preset", tag.is_preset)
        .done()
}

pub(super) fn tag(id: Uuid, fields: &Value, stored: Option<&ConnectionTag>) -> ConnectionTag {
    let name = text(fields, "name")
        .map(ConnectionTagName::from_stored)
        .or_else(|| stored.map(|stored| stored.name.clone()))
        .unwrap_or_else(|| ConnectionTagName::from_stored(""));
    ConnectionTag {
        id,
        name,
        color: match text(fields, "color") {
            Some("None") => None,
            Some(name) => color_named(name).or(Some(ConnectionColor::Slate)),
            None => Some(ConnectionColor::Slate),
        },
        is_preset: boolean(fields, "is_preset").unwrap_or(false),
    }
}
