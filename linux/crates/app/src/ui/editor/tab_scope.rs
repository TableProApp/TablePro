//! The database the tab works on, named in the editor bar.

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_core::dialect::DatabaseLayout;
use tablepro_session::Session;

use super::SqlEditor;
use crate::i18n::gettext_f;

/// The bar's text, dot-qualified as SQL spells a qualified name, and what
/// a screen reader says for it.
pub(super) fn scope_text(database: &str, schema: Option<&str>) -> (String, String) {
    match schema.filter(|schema| !schema.is_empty()) {
        Some(schema) => (
            format!("{database}.{schema}"),
            gettext_f(
                "{database}, schema {schema}",
                &[("database", database), ("schema", schema)],
            ),
        ),
        None => (database.to_owned(), database.to_owned()),
    }
}

impl SqlEditor {
    /// Name where the tab's next statement runs and, on an engine whose
    /// databases hold schemas, the schema completion resolves names in.
    pub(super) fn show_scope(&self) {
        let Some((session, tasks)) = self
            .deps()
            .and_then(|deps| deps.session.get().map(|session| (session, deps.tasks.clone())))
        else {
            self.set_scope(None);
            return;
        };
        let Some((database, layout)) = self.scope_database(&session) else {
            self.set_scope(None);
            return;
        };
        self.set_scope(Some(scope_text(&database, None)));
        // The catalog describes the connection's own database only.
        if layout != DatabaseLayout::WithSchemas || session.database() != Some(database.as_str()) {
            return;
        }
        let reading = {
            let session = session.clone();
            tasks.spawn_task(async move {
                session.schemas().await.ok().and_then(|schemas| {
                    schemas
                        .iter()
                        .find(|schema| schema.is_default)
                        .map(|schema| schema.name.clone())
                })
            })
        };
        let editor = self.downgrade();
        glib::spawn_future_local(async move {
            let Some(schema) = reading.await.ok().flatten() else {
                return;
            };
            if let Some(editor) = editor.upgrade()
                && editor.scope_database(&session).is_some_and(|(now, _)| now == database)
            {
                editor.set_scope(Some(scope_text(&database, Some(&schema))));
            }
        });
    }

    /// The database the tab's session last reported, else the
    /// connection's. `None` where a connection reaches one database.
    fn scope_database(&self, session: &Session) -> Option<(String, DatabaseLayout)> {
        let layout = session.current_dialect()?.database_layout();
        if layout == DatabaseLayout::Single {
            return None;
        }
        let database = self
            .imp()
            .slot
            .database()
            .or_else(|| session.database().map(str::to_owned))
            .filter(|name| !name.is_empty())?;
        Some((database, layout))
    }

    fn set_scope(&self, scope: Option<(String, String)>) {
        let imp = self.imp();
        let shown = scope.is_some();
        if let Some((text, spoken)) = scope {
            imp.scope_label.set_label(&text);
            imp.scope_box
                .update_property(&[gtk4::accessible::Property::Label(&spoken)]);
            imp.scope_box.set_tooltip_text(Some(&spoken));
        }
        imp.scope_box.set_visible(shown);
    }
}

#[cfg(test)]
mod tests {
    use super::scope_text;

    #[test]
    fn the_scope_names_the_database_then_its_schema() {
        assert_eq!(
            scope_text("shop", Some("public")),
            ("shop.public".to_owned(), "shop, schema public".to_owned())
        );
        assert_eq!(scope_text("shop", None), ("shop".to_owned(), "shop".to_owned()));
        assert_eq!(scope_text("shop", Some("")), ("shop".to_owned(), "shop".to_owned()));
    }
}
