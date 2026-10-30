//! The database the tab works on, named in the editor bar, and the menu
//! that moves the tab to another of the server's databases.

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use tablepro_core::dialect::DatabaseLayout;
use tablepro_core::meta::SchemaInfo;
use tablepro_session::Session;
use tablepro_session::operation::OperationKind;

use super::SqlEditor;
use super::completion::{CatalogHome, SqlCompletionProvider};
use crate::i18n::gettext_f;

/// The `editor` action a database menu item names, with the database as
/// its target.
pub(super) const MOVE_ACTION: &str = "database";

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

/// The user's databases, then the engine's own after a separator. `None`
/// when there is no other database to move to.
pub(super) fn database_menu(databases: &[SchemaInfo]) -> Option<gio::Menu> {
    if databases.len() < 2 {
        return None;
    }
    let menu = gio::Menu::new();
    for system in [false, true] {
        let section = gio::Menu::new();
        for database in databases.iter().filter(|database| database.is_system == system) {
            let item = gio::MenuItem::new(Some(&database.name), None);
            item.set_action_and_target_value(
                Some(&format!("editor.{MOVE_ACTION}")),
                Some(&database.name.to_variant()),
            );
            section.append_item(&item);
        }
        if section.n_items() > 0 {
            menu.append_section(None, &section);
        }
    }
    Some(menu)
}

/// Where completion resolves unqualified names for a tab in `database`.
pub(super) fn catalog_home(layout: DatabaseLayout, own: Option<&str>, database: &str) -> CatalogHome {
    match layout {
        _ if own == Some(database) => CatalogHome::Connection,
        DatabaseLayout::AsSchemas => CatalogHome::Schema(database.to_owned()),
        DatabaseLayout::WithSchemas | DatabaseLayout::Single => CatalogHome::Elsewhere,
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
        let own = self.own_database(&session);
        self.follow_in_completion(catalog_home(layout, own.as_deref(), &database));
        let moved = self.imp().named_database.replace(Some(database.clone())) != Some(database.clone());
        if moved {
            self.emit_by_name::<()>("database-changed", &[]);
        }
        if let Some(action) = super::imp_action(self, MOVE_ACTION) {
            action.set_state(&database.to_variant());
        }
        // The catalog describes the connection's own database only.
        if layout != DatabaseLayout::WithSchemas || own.as_deref() != Some(database.as_str()) {
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

    /// The tab's database, else the connection's. `None` where a
    /// connection reaches one database.
    fn scope_database(&self, session: &Session) -> Option<(String, DatabaseLayout)> {
        let layout = session.current_dialect()?.database_layout();
        if layout == DatabaseLayout::Single {
            return None;
        }
        let database = self
            .imp()
            .slot
            .database()
            .or_else(|| self.own_database(session))
            .filter(|name| !name.is_empty())?;
        Some((database, layout))
    }

    /// The database the connection opened in: the name it was given, else
    /// the one the server listed as its own.
    fn own_database(&self, session: &Session) -> Option<String> {
        session
            .database()
            .filter(|name| !name.is_empty())
            .map(str::to_owned)
            .or_else(|| self.imp().listed_own_database.borrow().clone())
    }

    /// Ask the server for its databases, for the bar's menu. A server
    /// that cannot list them leaves the bar a label.
    pub(super) fn list_databases(&self) {
        let Some((session, tasks)) = self
            .deps()
            .and_then(|deps| deps.session.get().map(|session| (session, deps.tasks.clone())))
        else {
            return;
        };
        let several = session
            .current_dialect()
            .is_some_and(|dialect| dialect.database_layout() != DatabaseLayout::Single);
        if !several {
            return;
        }
        let listing = tasks.spawn_task(async move {
            session
                .run(OperationKind::Metadata, |lease, options| async move {
                    Ok(lease.list_databases(options).await?)
                })
                .await
        });
        let editor = self.downgrade();
        glib::spawn_future_local(async move {
            let databases = match listing.await {
                Ok(Ok(databases)) => databases,
                Ok(Err(error)) => {
                    tracing::debug!(%error, "the server's databases could not be listed for the editor bar");
                    return;
                }
                Err(failure) => {
                    tracing::debug!(%failure, "listing the server's databases failed");
                    return;
                }
            };
            if let Some(editor) = editor.upgrade() {
                let imp = editor.imp();
                let own = databases.iter().find(|database| database.is_default);
                imp.listed_own_database
                    .replace(own.map(|database| database.name.clone()));
                imp.scope_button.set_menu_model(database_menu(&databases).as_ref());
                editor.show_scope();
            }
        });
    }

    /// Point the tab at `database`: its next run goes there, completion
    /// resolves names there, and the bar names it.
    pub(crate) fn move_to_database(&self, database: &str) {
        if self.imp().slot.database().as_deref() == Some(database) {
            return;
        }
        self.imp().slot.set_database(database.to_owned());
        self.show_scope();
    }

    /// The database a restore puts the tab back in: `None` while it is
    /// the connection's own.
    pub(crate) fn tab_database(&self) -> Option<String> {
        let database = self.imp().slot.database()?;
        let own = self
            .deps()
            .and_then(|deps| deps.session.get())
            .and_then(|session| self.own_database(&session));
        (own.as_deref() != Some(database.as_str())).then_some(database)
    }

    pub(crate) fn connect_database_changed<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "database-changed",
            false,
            glib::closure_local!(move |editor: &Self| f(editor)),
        )
    }

    fn follow_in_completion(&self, home: CatalogHome) {
        for provider in self.imp().completion_providers.borrow().iter() {
            if let Some(provider) = provider.downcast_ref::<SqlCompletionProvider>() {
                provider.set_home(home.clone());
            }
        }
    }

    fn set_scope(&self, scope: Option<(String, String)>) {
        let imp = self.imp();
        let switchable = imp.scope_button.menu_model().is_some();
        let Some((text, spoken)) = scope else {
            imp.scope_box.set_visible(false);
            imp.scope_button.set_visible(false);
            return;
        };
        imp.scope_label.set_label(&text);
        imp.scope_button_label.set_label(&text);
        imp.scope_box
            .update_property(&[gtk4::accessible::Property::Label(&spoken)]);
        imp.scope_box.set_tooltip_text(Some(&spoken));
        imp.scope_button
            .update_property(&[gtk4::accessible::Property::Label(&spoken)]);
        imp.scope_box.set_visible(!switchable);
        imp.scope_button.set_visible(switchable);
    }
}

#[cfg(test)]
mod tests {
    use gtk4::gio;
    use gtk4::prelude::*;
    use tablepro_core::dialect::DatabaseLayout;
    use tablepro_core::meta::SchemaInfo;

    use super::{CatalogHome, catalog_home, database_menu, scope_text};

    #[test]
    fn the_scope_names_the_database_then_its_schema() {
        assert_eq!(
            scope_text("shop", Some("public")),
            ("shop.public".to_owned(), "shop, schema public".to_owned())
        );
        assert_eq!(scope_text("shop", None), ("shop".to_owned(), "shop".to_owned()));
        assert_eq!(scope_text("shop", Some("")), ("shop".to_owned(), "shop".to_owned()));
    }

    fn database(name: &str, is_system: bool) -> SchemaInfo {
        SchemaInfo {
            name: name.to_owned(),
            is_default: false,
            is_system,
        }
    }

    fn labels(menu: &gio::Menu, section: i32) -> Vec<String> {
        let section = menu.item_link(section, "section").expect("a section");
        (0..section.n_items())
            .filter_map(|item| {
                section
                    .item_attribute_value(item, "label", None)
                    .and_then(|label| label.str().map(str::to_owned))
            })
            .collect()
    }

    #[test]
    fn the_menu_lists_the_users_databases_then_the_engines_own() {
        let menu = database_menu(&[
            database("mysql", true),
            database("shop", false),
            database("analytics", false),
            database("information_schema", true),
        ])
        .expect("a menu");

        assert_eq!(menu.n_items(), 2, "two sections");
        assert_eq!(labels(&menu, 0), ["shop", "analytics"]);
        assert_eq!(labels(&menu, 1), ["mysql", "information_schema"]);
        assert!(
            database_menu(&[database("shop", false)]).is_none(),
            "nothing to move to"
        );
    }

    /// A database the catalog does not describe offers no tables, rather
    /// than the connection's under the wrong database.
    #[test]
    fn completion_resolves_where_the_catalog_reaches() {
        assert_eq!(
            catalog_home(DatabaseLayout::AsSchemas, Some("shop"), "shop"),
            CatalogHome::Connection
        );
        assert_eq!(
            catalog_home(DatabaseLayout::AsSchemas, Some("shop"), "analytics"),
            CatalogHome::Schema("analytics".to_owned())
        );
        assert_eq!(
            catalog_home(DatabaseLayout::WithSchemas, Some("shop"), "analytics"),
            CatalogHome::Elsewhere
        );
    }
}
