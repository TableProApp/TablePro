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
                objects: schema_objects(&session, &name).await,
                columns: columns_of(&session, table.into_iter().collect()).await,
            }
        }
        CompletionScope::Qualified { qualifier, name } => {
            let table = TableRef::new(Some(qualifier), name.clone());
            match known_table(&session, &defaults, &table).await {
                Some(table) => CatalogAnswer {
                    columns: columns_of(&session, vec![table]).await,
                    ..CatalogAnswer::default()
                },
                None => CatalogAnswer {
                    objects: schema_objects(&session, &name).await,
                    ..CatalogAnswer::default()
                },
            }
        }
        CompletionScope::Columns { tables } => CatalogAnswer {
            columns: columns_of(&session, known_tables(&session, &defaults, &tables).await).await,
            ..CatalogAnswer::default()
        },
        CompletionScope::General { tables_in_statement } => CatalogAnswer {
            schemas: None,
            columns: columns_of(&session, known_tables(&session, &defaults, &tables_in_statement).await).await,
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

/// The objects of the schema called `name`, or `None` when the catalog
/// has no such schema.
async fn schema_objects(session: &Session, name: &str) -> Option<Arc<[ObjectInfo]>> {
    let schemas = listed(session.schemas().await);
    let schema = schema_named(&schemas, name)?;
    Some(listed(session.objects(ObjectScope::Schema(schema.name.clone())).await))
}

/// The catalog's own names for the tables among `tables` it holds. A
/// name it does not hold, such as a CTE's, is left out: reading it
/// could only fail, and a failed read is asked again every time.
async fn known_tables(session: &Session, defaults: &[ObjectInfo], tables: &[TableRef]) -> Vec<TableRef> {
    let mut known = Vec::new();
    for table in tables {
        if let Some(table) = known_table(session, defaults, table).await
            && !known.contains(&table)
        {
            known.push(table);
        }
    }
    known
}

/// The catalog's own name for `table`, so the read is the one the
/// table's other views share.
async fn known_table(session: &Session, defaults: &[ObjectInfo], table: &TableRef) -> Option<TableRef> {
    let Some(schema) = &table.schema else {
        return relation_named(defaults, &table.name);
    };
    let schemas = listed(session.schemas().await);
    let schema = schema_named(&schemas, schema)?;
    if schema.is_default {
        return relation_named(defaults, &table.name);
    }
    let objects = listed(session.objects(ObjectScope::Schema(schema.name.clone())).await);
    relation_named(&objects, &table.name)
}

fn schema_named<'a>(schemas: &'a [SchemaInfo], name: &str) -> Option<&'a SchemaInfo> {
    named(schemas, name, |schema| Some(schema.name.as_str()))
}

fn relation_named(objects: &[ObjectInfo], name: &str) -> Option<TableRef> {
    named(objects, name, |object| {
        object.kind.is_browsable().then_some(object.name.as_str())
    })
    .map(|object| TableRef::new(object.schema.clone(), object.name.clone()))
}

/// The item called `name`, as written or, failing that, ignoring case
/// the way an unquoted name is read. `name_of` gives `None` for an item
/// that does not count.
fn named<'a, T>(items: &'a [T], name: &str, name_of: impl Fn(&T) -> Option<&str>) -> Option<&'a T> {
    let folded = name.to_lowercase();
    items.iter().find(|item| name_of(item) == Some(name)).or_else(|| {
        items
            .iter()
            .find(|item| name_of(item).is_some_and(|own| own.to_lowercase() == folded))
    })
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
            relation_named(&defaults, "users"),
            Some(TableRef::new(Some("public".to_owned()), "users"))
        );
        assert_eq!(
            relation_named(&defaults, "orders"),
            Some(TableRef::new(Some("public".to_owned()), "Orders"))
        );
        assert_eq!(relation_named(&defaults, "missing"), None);
    }

    #[test]
    fn a_function_is_not_a_relation() {
        let defaults = [object("refresh", ObjectKind::Function)];

        assert_eq!(relation_named(&defaults, "refresh"), None);
    }

    #[test]
    fn a_schema_is_matched_as_written_then_ignoring_case() {
        let schema = |name: &str| SchemaInfo {
            name: name.to_owned(),
            is_default: false,
            is_system: false,
        };
        let schemas = [schema("sales"), schema("Audit"), schema("audit")];

        assert_eq!(
            schema_named(&schemas, "SALES").map(|schema| schema.name.as_str()),
            Some("sales")
        );
        assert_eq!(
            schema_named(&schemas, "Audit").map(|schema| schema.name.as_str()),
            Some("Audit")
        );
        assert_eq!(
            schema_named(&schemas, "audit").map(|schema| schema.name.as_str()),
            Some("audit")
        );
        assert!(schema_named(&schemas, "hr").is_none());
    }
}
