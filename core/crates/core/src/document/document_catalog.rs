use crate::meta::TableRef;
use crate::sql_syntax::mongo::{CallRoot, ShellCall, ShellMethod, ShellValue};
use crate::statement::Statement;

use super::ShellParams;
use super::document_read::collection;

/// Delete every document and keep the collection with its indexes and
/// options, which `drop()` would take too.
pub(crate) fn delete_all_documents(table: &TableRef) -> Statement {
    let mut call = collection(table);
    call.methods
        .push(ShellMethod::new("deleteMany", vec![ShellValue::Object(Vec::new())]));
    ShellParams::new().statement(&call)
}

/// MongoDB keeps a database only once something is stored in it, so a
/// new one is made by creating its first collection.
pub(crate) fn create_database(database: &str, first_collection: &str) -> Statement {
    let mut call = database_call(database);
    call.methods.push(ShellMethod::new(
        "createCollection",
        vec![ShellValue::string(first_collection)],
    ));
    ShellParams::new().statement(&call)
}

pub(crate) fn drop_database(database: &str) -> Statement {
    let mut call = database_call(database);
    call.methods.push(ShellMethod::new("dropDatabase", Vec::new()));
    ShellParams::new().statement(&call)
}

fn database_call(database: &str) -> ShellCall {
    ShellCall {
        root: CallRoot::Db,
        database: Some(database.to_owned()),
        collection: None,
        methods: Vec::new(),
    }
}
