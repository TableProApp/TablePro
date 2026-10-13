use std::sync::Arc;

use tablepro_core::meta::{ObjectInfo, ObjectScope, SchemaInfo};
use tablepro_core::{ColumnInfo, TableRef};
use tablepro_session::{OperationError, Session};

use super::completion_scope::CompletionScope;

/// What the session's catalog holds for one completion.
#[derive(Debug, Default)]
pub struct CatalogAnswer {
    pub schemas: Option<Arc<[SchemaInfo]>>,
    pub objects: Option<Arc<[ObjectInfo]>>,
    pub columns: Vec<(TableRef, Arc<[ColumnInfo]>)>,
}

/// Read what `scope` offers. The catalog shares each read with every
/// other view and keeps what it read, so typing does not reach the
/// server again; a list that cannot be read is left out.
pub async fn read(session: Arc<Session>, scope: CompletionScope) -> CatalogAnswer {
    let defaults = listed(session.objects(ObjectScope::DefaultSchema).await);
    match scope {
        CompletionScope::Objects { schema: None } => CatalogAnswer {
            schemas: Some(listed(session.schemas().await)),
            objects: Some(defaults),
            columns: Vec::new(),
        },
        CompletionScope::Objects { schema: Some(name) } => {
            // `users.` typed before the FROM that names users.
            let table = relation_named(&defaults, &name);
            CatalogAnswer {
                schemas: None,
                objects: Some(listed(session.objects(ObjectScope::Schema(name)).await)),
                columns: columns_of(&session, table.into_iter().collect()).await,
            }
        }
        CompletionScope::Columns { tables } => CatalogAnswer {
            schemas: None,
            objects: None,
            columns: columns_of(&session, resolved(&tables, &defaults)).await,
        },
        CompletionScope::General { tables_in_statement } => CatalogAnswer {
            schemas: None,
            columns: columns_of(&session, resolved(&tables_in_statement, &defaults)).await,
            objects: Some(defaults),
        },
    }
}

async fn columns_of(session: &Session, tables: Vec<TableRef>) -> Vec<(TableRef, Arc<[ColumnInfo]>)> {
    let reads = tables.into_iter().map(|table| async move {
        let columns = listed(session.columns(table.clone()).await);
        (table, columns)
    });
    futures::future::join_all(reads).await
}

fn listed<T>(read: Result<Arc<[T]>, Arc<OperationError>>) -> Arc<[T]> {
    read.unwrap_or_else(|error| {
        tracing::debug!(%error, "completion left out a list it could not read");
        Arc::from([])
    })
}

fn resolved(tables: &[TableRef], defaults: &[ObjectInfo]) -> Vec<TableRef> {
    tables.iter().map(|table| resolve(table, defaults)).collect()
}

/// The catalog's own name for a table the statement names without a
/// schema, so the read is the one the table's other views share.
fn resolve(table: &TableRef, defaults: &[ObjectInfo]) -> TableRef {
    if table.schema.is_some() {
        return table.clone();
    }
    relation_named(defaults, &table.name).unwrap_or_else(|| table.clone())
}

/// The default schema's relation called `name`, as written or, failing
/// that, ignoring case the way an unquoted name is read.
fn relation_named(defaults: &[ObjectInfo], name: &str) -> Option<TableRef> {
    let relations = || defaults.iter().filter(|object| object.kind.is_browsable());
    let folded = name.to_lowercase();
    relations()
        .find(|object| object.name == name)
        .or_else(|| relations().find(|object| object.name.to_lowercase() == folded))
        .map(|object| TableRef::new(object.schema.clone(), object.name.clone()))
}

#[cfg(test)]
mod tests {
    use tablepro_core::meta::ObjectKind;

    use super::*;

    fn object(name: &str, kind: ObjectKind) -> ObjectInfo {
        ObjectInfo {
            schema: Some("public".to_owned()),
            name: name.to_owned(),
            kind,
        }
    }

    #[test]
    fn an_unqualified_table_takes_the_catalogs_schema() {
        let defaults = [object("users", ObjectKind::Table), object("Orders", ObjectKind::Table)];

        assert_eq!(
            resolve(&TableRef::unqualified("users"), &defaults),
            TableRef::new(Some("public".to_owned()), "users")
        );
        assert_eq!(
            resolve(&TableRef::unqualified("orders"), &defaults),
            TableRef::new(Some("public".to_owned()), "Orders")
        );
        assert_eq!(
            resolve(&TableRef::unqualified("missing"), &defaults),
            TableRef::unqualified("missing")
        );
        let qualified = TableRef::new(Some("sales".to_owned()), "users");
        assert_eq!(resolve(&qualified, &defaults), qualified);
    }

    #[test]
    fn a_function_is_not_a_relation() {
        let defaults = [object("refresh", ObjectKind::Function)];

        assert_eq!(relation_named(&defaults, "refresh"), None);
    }
}
