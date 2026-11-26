// What a table folder or a filed table needs before its store can hold it, as the Mac's decoders require it
// (`SyncRecordMapper`): a record without it is one this build cannot read, held by its id (0054, Rules for both
// providers), never applied and never read as a deletion. A filed table is named by the table, so fields that name
// another table are not this record. Every other kind's store takes any record its schema shapes.

use serde_json::Value;

use crate::kind::Kind;
use crate::record_id::table_folder_item;

fn text<'a>(fields: &'a Value, key: &str) -> Option<&'a str> {
    fields.get(key).and_then(Value::as_str)
}

// As Swift's `UUID(uuidString:)` reads one: hyphenated, in either case.
fn uuid(fields: &Value, key: &str) -> Option<uuid::Uuid> {
    text(fields, key)
        .filter(|raw| raw.len() == 36)
        .and_then(|raw| uuid::Uuid::try_parse(raw).ok())
}

pub fn readable(kind: Kind, record_id: &str, fields: &Value) -> bool {
    match kind {
        // The core's store holds no folder without a name.
        Kind::TableFolder => {
            uuid(fields, "connection_id").is_some() && text(fields, "name").is_some_and(|name| !name.trim().is_empty())
        }
        Kind::TableFolderItem => {
            let (Some(connection), Some(_), Some(name)) = (
                uuid(fields, "connection_id"),
                uuid(fields, "folder_id"),
                text(fields, "name").filter(|name| !name.is_empty()),
            ) else {
                return false;
            };
            let database = text(fields, "database").unwrap_or_default();
            table_folder_item(connection, database, text(fields, "schema"), name) == record_id
        }
        _ => true,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    const CONNECTION: &str = "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44";
    const FOLDER: &str = "E6C12C96-3CBD-4A0E-9F41-E36B47F35D84";

    #[test]
    fn a_folder_without_what_its_store_needs_is_unreadable() {
        let folder = json!({"connection_id": CONNECTION, "name": "Billing"});
        let blank = json!({"connection_id": CONNECTION, "name": " "});

        assert!(readable(Kind::TableFolder, FOLDER, &folder));
        assert!(!readable(Kind::TableFolder, FOLDER, &json!({"name": "Billing"})));
        assert!(!readable(Kind::TableFolder, FOLDER, &blank));
        assert!(readable(Kind::Connection, CONNECTION, &json!({"name": "Shop"})));
    }

    #[test]
    fn a_filed_table_is_readable_only_under_the_id_of_the_table_it_names() {
        let connection = uuid::Uuid::parse_str(CONNECTION).unwrap();
        let id = table_folder_item(connection, "shop", None, "orders");
        let item = json!({"connection_id": CONNECTION, "database": "shop", "name": "orders", "folder_id": FOLDER});
        let mut other = item.clone();
        other["name"] = json!("invoices");
        let unfiled = json!({"connection_id": CONNECTION, "database": "shop", "name": "orders"});

        assert!(readable(Kind::TableFolderItem, &id, &item));
        assert!(!readable(Kind::TableFolderItem, &id, &other));
        assert!(!readable(Kind::TableFolderItem, &id, &unfiled));
    }
}
