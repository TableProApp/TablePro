// Groups and tags as the Mac's mapper writes them (`SyncRecordMapper`, Connection Group and Connection Tag): a group's
// colour is always named, "None" for none, and its icon and parent only when it has one; a tag's colour is always
// named, and one with none reads as Gray, as the Mac reads it.

use serde_json::Value;
use tablepro_records::cloudkit::library::{color_name, color_named, icon_for_symbol, symbol_for_icon};
use tablepro_storage::{ConnectionColor, ConnectionGroup, ConnectionGroupName, ConnectionTag, ConnectionTagName};
use uuid::Uuid;

use super::values::{Object, boolean, clamped, integer, text, uuid_at, uuid_value};

pub(super) fn group_to_wire(group: &ConnectionGroup) -> Value {
    Object::default()
        .put("name", group.name.as_str())
        .put("color", color_name(group.color))
        .put_some("icon_name", group.icon.as_ref().and_then(symbol_for_icon))
        .put_some("parent_id", group.parent_id.map(uuid_value))
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
        order: integer(fields, "sort_order").map_or(0, clamped),
        color: text(fields, "color").and_then(color_named),
        icon: text(fields, "icon_name").and_then(icon_for_symbol),
    }
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
        color: text(fields, "color").map_or(Some(ConnectionColor::Slate), color_named),
        is_preset: boolean(fields, "is_preset").unwrap_or(false),
    }
}
