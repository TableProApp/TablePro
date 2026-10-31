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

/// Where an unqualified name resolves for the tab.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum CatalogHome {
    /// The connection's default schema.
    #[default]
    Connection,
    /// Another of the server's databases, which the catalog lists as a
    /// schema.
    Schema(String),
    /// A database the catalog does not describe, which nothing offered
    /// from it would be right for.
    Elsewhere(String),
}

/// Read what `scope` offers. The catalog shares each read with every
/// other view and keeps what it read, so typing does not reach the
/// server again; a list that cannot be read is left out.
pub async fn read(session: Arc<Session>, scope: CompletionScope, home: CatalogHome) -> CatalogAnswer {
    let defaults = match &home {
        CatalogHome::Connection => listed(session.objects(ObjectScope::DefaultSchema).await),
        CatalogHome::Schema(name) => listed(session.objects(ObjectScope::Schema(name.clone())).await),
        CatalogHome::Elsewhere(_) => return CatalogAnswer::default(),
    };
    let home = Home { home, defaults };
    match scope {
        CompletionScope::Objects { schema: None } => CatalogAnswer {
            schemas: Some(listed(session.schemas().await)),
            objects: Some(home.defaults.clone()),
            columns: Vec::new(),
        },
        CompletionScope::Objects { schema: Some(name) } => {
            // `users.` typed before the FROM that names users.
            let table = relation_named(&home.defaults, &name);
            CatalogAnswer {
                schemas: None,
                objects: schema_objects(&session, &home, &name).await,
                columns: columns_of(&session, table.into_iter().collect()).await,
            }
        }
        CompletionScope::Qualified { qualifier, name } => {
            let table = TableRef::new(Some(qualifier), name.clone());
            match known_table(&session, &home, &table).await {
                Some(table) => CatalogAnswer {
                    columns: columns_of(&session, vec![table]).await,
                    ..CatalogAnswer::default()
                },
                None => CatalogAnswer {
                    objects: schema_objects(&session, &home, &name).await,
                    ..CatalogAnswer::default()
                },
            }
        }
        CompletionScope::Columns { tables } => CatalogAnswer {
            columns: columns_of(&session, known_tables(&session, &home, &tables).await).await,
            ..CatalogAnswer::default()
        },
        CompletionScope::General { tables_in_statement } => CatalogAnswer {
            schemas: None,
            columns: columns_of(&session, known_tables(&session, &home, &tables_in_statement).await).await,
            objects: Some(home.defaults),
        },
    }
}

/// The schema unqualified names resolve in and what it holds.
struct Home {
    home: CatalogHome,
    defaults: Arc<[ObjectInfo]>,
}

impl Home {
    /// Whether `schema` names the home schema, whose objects are read.
    fn is(&self, schema: &SchemaInfo) -> bool {
        match &self.home {
            CatalogHome::Connection => schema.is_default,
            CatalogHome::Schema(name) => schema.name == *name,
            CatalogHome::Elsewhere(_) => false,
        }
    }

    /// A name for the home database the catalog does not list as a
    /// schema, as MySQL lists only the connection's. Exact, since
    /// `Analytics` and `analytics` can be two databases.
    fn named(&self, name: &str) -> bool {
        matches!(&self.home, CatalogHome::Schema(home) if home == name)
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
async fn schema_objects(session: &Session, home: &Home, name: &str) -> Option<Arc<[ObjectInfo]>> {
    if home.named(name) {
        return Some(home.defaults.clone());
    }
    let schemas = listed(session.schemas().await);
    let schema = schema_named(&schemas, name)?;
    Some(listed(session.objects(ObjectScope::Schema(schema.name.clone())).await))
}

/// The catalog's own names for the tables among `tables` it holds. A
/// name it does not hold, such as a CTE's, is left out: reading it
/// could only fail, and a failed read is asked again every time.
async fn known_tables(session: &Session, home: &Home, tables: &[TableRef]) -> Vec<TableRef> {
    let mut known = Vec::new();
    for table in tables {
        if let Some(table) = known_table(session, home, table).await
            && !known.contains(&table)
        {
            known.push(table);
        }
    }
    known
}

/// The catalog's own name for `table`, so the read is the one the
/// table's other views share.
async fn known_table(session: &Session, home: &Home, table: &TableRef) -> Option<TableRef> {
    let Some(schema) = &table.schema else {
        return relation_named(&home.defaults, &table.name);
    };
    if home.named(schema) {
        return relation_named(&home.defaults, &table.name);
    }
    let schemas = listed(session.schemas().await);
    let schema = schema_named(&schemas, schema)?;
    if home.is(schema) {
        return relation_named(&home.defaults, &table.name);
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

    /// A tab moved to `analytics` reads `shop.orders` from `shop`, the
    /// connection's default schema, not from its own.
    #[test]
    fn only_the_tabs_own_database_is_read_from_its_home() {
        let shop = SchemaInfo {
            name: "shop".to_owned(),
            is_default: true,
            is_system: false,
        };
        let moved = Home {
            home: CatalogHome::Schema("analytics".to_owned()),
            defaults: Arc::from([]),
        };
        assert!(!moved.is(&shop));
        assert!(moved.named("analytics"));
        let staying = Home {
            home: CatalogHome::Connection,
            defaults: Arc::from([]),
        };
        assert!(staying.is(&shop));
        assert!(!staying.named("shop"), "the catalog lists the connection's own");
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
