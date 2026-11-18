use std::collections::HashSet;
use std::sync::Arc;

use tablepro_ai::{ColumnShape, MAX_DESCRIBED_TABLES, QueryLanguage, SchemaContext, TableShape};
use tablepro_core::dialect::DatabaseLayout;
use tablepro_core::meta::{ObjectInfo, ObjectScope, TableRef};
use tablepro_session::Session;

// The schema the user is in, its tables, and the structure of the tables `text` names. Read from the
// session's catalog, which the tree and the filters share: never a row.
pub(crate) async fn read(session: Arc<Session>, engine: String, text: &str, database: Option<String>) -> SchemaContext {
    let dialect = session.current_dialect();
    let language = match &dialect {
        Some(dialect) if !dialect.grammar().is_sql() => QueryLanguage::Commands,
        _ => QueryLanguage::Sql,
    };
    let own = session.database().filter(|name| !name.is_empty()).map(str::to_owned);
    let elsewhere = database.filter(|name| !name.is_empty() && Some(name) != own.as_ref());
    let layout = dialect.map(|dialect| dialect.database_layout());
    let (scope, schema, database) = match elsewhere {
        // Where the server's databases are the catalog's schemas, the editor's is read as one.
        Some(name) if layout == Some(DatabaseLayout::AsSchemas) => {
            (ObjectScope::Schema(name.clone()), Some(name.clone()), Some(name))
        }
        // Nothing the connection's catalog holds is in that database.
        Some(name) => {
            return SchemaContext {
                engine,
                language,
                database: Some(name),
                ..SchemaContext::default()
            };
        }
        None => (ObjectScope::DefaultSchema, default_schema(&session).await, own),
    };
    let objects = match session.objects(scope).await {
        Ok(objects) => objects,
        Err(error) => {
            tracing::warn!(%error, "the tables for the assistant could not be read");
            Arc::from([])
        }
    };
    let browsable: Vec<&ObjectInfo> = objects.iter().filter(|object| object.kind.is_browsable()).collect();
    let mut described = Vec::new();
    for object in named_in(text, &browsable).into_iter().take(MAX_DESCRIBED_TABLES) {
        let table = TableRef::new(object.schema.clone(), object.name.clone());
        match session.columns(table).await {
            Ok(columns) if !columns.is_empty() => described.push(TableShape {
                name: object.name.clone(),
                columns: columns
                    .iter()
                    .map(|column| ColumnShape {
                        name: column.name.clone(),
                        type_name: column.column_type.name.clone(),
                        nullable: column.nullable,
                        primary_key: column.primary_key,
                    })
                    .collect(),
            }),
            Ok(_) => {}
            Err(error) => tracing::warn!(%error, "a table's columns for the assistant could not be read"),
        }
    }
    SchemaContext {
        engine,
        language,
        database,
        schema,
        tables: browsable.iter().map(|object| object.name.clone()).collect(),
        described,
    }
}

async fn default_schema(session: &Session) -> Option<String> {
    let schemas = session.schemas().await.ok()?;
    schemas
        .iter()
        .find(|schema| schema.is_default)
        .map(|schema| schema.name.clone())
}

// The objects whose names stand in `text` as words, ignoring case, in the order the catalog lists them. A question
// in words names tables as words too, so one rule serves a statement and a question.
fn named_in<'a>(text: &str, objects: &[&'a ObjectInfo]) -> Vec<&'a ObjectInfo> {
    let words: HashSet<String> = text
        .split(|c: char| !(c.is_alphanumeric() || c == '_'))
        .filter(|word| !word.is_empty())
        .map(str::to_lowercase)
        .collect();
    objects
        .iter()
        .copied()
        .filter(|object| words.contains(&object.name.to_lowercase()))
        .collect()
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
            parent_table: None,
        }
    }

    #[test]
    fn a_statement_or_a_question_names_the_tables_it_mentions_in_catalog_order() {
        let objects = [
            object("orders", ObjectKind::Table),
            object("Customers", ObjectKind::View),
            object("items", ObjectKind::Table),
            object("order_total", ObjectKind::Table),
        ];
        let listed: Vec<&ObjectInfo> = objects.iter().collect();

        let question = named_in("Which customers have open orders?", &listed);
        let statement = named_in("SELECT * FROM public.items i JOIN \"Orders\" o ON true", &listed);

        assert_eq!(
            question.iter().map(|object| object.name.as_str()).collect::<Vec<_>>(),
            ["orders", "Customers"]
        );
        assert_eq!(
            statement.iter().map(|object| object.name.as_str()).collect::<Vec<_>>(),
            ["orders", "items"]
        );
    }
}
