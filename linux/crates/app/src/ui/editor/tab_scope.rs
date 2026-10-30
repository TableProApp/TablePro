//! The database the tab works on, named in the editor bar as the macOS
//! editor names it (`QueryContainerPicker`): the database, then the schema
//! an unqualified name resolves to where the engine nests schemas in a
//! database. A file's name is already in the window title and the sidebar.

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

use super::SqlEditor;
use crate::i18n::gettext_f;

/// The bar's text, dot-qualified as SQL and the sidebar spell a qualified
/// object, and what a screen reader says for it. `None` with no database.
pub(super) fn scope_text(database: Option<&str>, default_schema: Option<&str>) -> Option<(String, String)> {
    let database = database.filter(|database| !database.is_empty())?;
    // Where the engine's schemas are its databases, as on MySQL, the
    // default one is the database itself and adds nothing.
    match default_schema.filter(|schema| !schema.is_empty() && *schema != database) {
        Some(schema) => Some((
            format!("{database}.{schema}"),
            gettext_f(
                "{database}, schema {schema}",
                &[("database", database), ("schema", schema)],
            ),
        )),
        None => Some((database.to_owned(), database.to_owned())),
    }
}

impl SqlEditor {
    /// Name the tab's database now, and its schema once the catalog has
    /// listed the schemas.
    pub(super) fn show_scope(&self) {
        let Some((session, tasks)) = self
            .deps()
            .and_then(|deps| deps.session.get().map(|session| (session, deps.tasks.clone())))
        else {
            self.set_scope(None);
            return;
        };
        let database = session.database().map(str::to_owned);
        self.set_scope(scope_text(database.as_deref(), None));
        if database.is_none() {
            return;
        }
        // The catalog reads on the runtime, as completion's reads do.
        let reading = tasks.spawn_task(async move {
            session.schemas().await.ok().and_then(|schemas| {
                schemas
                    .iter()
                    .find(|schema| schema.is_default)
                    .map(|schema| schema.name.clone())
            })
        });
        let editor = self.downgrade();
        glib::spawn_future_local(async move {
            let default = reading.await.ok().flatten();
            if let Some(editor) = editor.upgrade() {
                editor.set_scope(scope_text(database.as_deref(), default.as_deref()));
            }
        });
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
    fn the_scope_names_the_database_then_a_schema_of_its_own() {
        assert_eq!(
            scope_text(Some("shop"), Some("public")),
            Some(("shop.public".to_owned(), "shop, schema public".to_owned()))
        );
        assert_eq!(
            scope_text(Some("shop"), Some("shop")),
            Some(("shop".to_owned(), "shop".to_owned())),
            "a schema that is the database"
        );
        assert_eq!(
            scope_text(Some("shop"), None),
            Some(("shop".to_owned(), "shop".to_owned()))
        );
        assert_eq!(scope_text(None, Some("main")), None, "a file");
        assert_eq!(scope_text(Some(""), None), None);
    }
}
