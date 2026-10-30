//! The database the tab works on, named in the editor bar as the macOS
//! editor names it (`QueryContainerPicker`): the database, then the schema
//! an unqualified name resolves to where the engine nests schemas in a
//! database. Where the server has other databases and the connection may
//! write, the name is a menu of them, the user's first and the engine's own
//! after, and picking one moves the tab there. A file's name is already in
//! the window title and the sidebar.

use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use tablepro_core::meta::SchemaInfo;
use tablepro_session::Session;
use tablepro_session::operation::OperationKind;
use tablepro_session::runtime::Tasks;

use super::SqlEditor;
use super::editor_session_slot::TabDatabase;
use crate::i18n::{gettext, gettext_f};

/// The action a database menu item names, with the database as target.
const SWITCH_ACTION: &str = "database";

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

/// The menu's sections as macOS orders them: the user's databases, then
/// the engine's own after a separator. `None` when there is no other
/// database to move to.
pub(super) fn database_menu(databases: &[SchemaInfo]) -> Option<gio::Menu> {
    if databases.len() < 2 {
        return None;
    }
    let menu = gio::Menu::new();
    for system in [false, true] {
        let section = gio::Menu::new();
        for database in databases.iter().filter(|database| database.is_system == system) {
            let item = gio::MenuItem::new(Some(&database.name), None);
            item.set_action_and_target_value(Some(&format!("tab.{SWITCH_ACTION}")), Some(&database.name.to_variant()));
            section.append_item(&item);
        }
        if section.n_items() > 0 {
            menu.append_section(None, &section);
        }
    }
    Some(menu)
}

impl SqlEditor {
    /// Name the tab's database now, its schema once the catalog has listed
    /// the schemas, and offer the server's others once they are listed.
    pub(super) fn show_scope(&self) {
        self.install_database_action();
        let Some((session, tasks)) = self
            .deps()
            .and_then(|deps| deps.session.get().map(|session| (session, deps.tasks.clone())))
        else {
            self.set_scope(None);
            return;
        };
        if let Some(moved) = self.imp().slot.database() {
            self.set_scope(scope_text(Some(&moved.name), None));
            self.list_databases(&session, &tasks, &moved.name);
            return;
        }
        let database = session.database().map(str::to_owned);
        self.set_scope(scope_text(database.as_deref(), None));
        let Some(database) = database else {
            return;
        };
        self.list_databases(&session, &tasks, &database);
        // The catalog reads on the runtime, as completion's reads do.
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
            let default = reading.await.ok().flatten();
            if let Some(editor) = editor.upgrade()
                && editor.imp().slot.database().is_none()
            {
                editor.set_scope(scope_text(Some(&database), default.as_deref()));
            }
        });
    }

    /// Ask the server for its databases. A connection that may not write
    /// keeps the label, as on macOS, and so does an engine that cannot
    /// list them.
    fn list_databases(&self, session: &Arc<Session>, tasks: &Tasks, current: &str) {
        if session.read_only() {
            return;
        }
        let listing = {
            let session = session.clone();
            tasks.spawn_task(async move {
                session
                    .run(OperationKind::Metadata, |lease, options| async move {
                        Ok(lease.list_databases(options).await?)
                    })
                    .await
            })
        };
        let editor = self.downgrade();
        let current = current.to_owned();
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
                editor.offer_databases(&databases, &current);
            }
        });
    }

    fn offer_databases(&self, databases: &[SchemaInfo], current: &str) {
        let Some(menu) = database_menu(databases) else {
            return;
        };
        let imp = self.imp();
        imp.scope_button.set_menu_model(Some(&menu));
        let current = imp
            .slot
            .database()
            .map_or_else(|| current.to_owned(), |moved| moved.name);
        if let Some(action) = self.database_action() {
            action.set_state(&current.to_variant());
        }
        imp.scope_box.set_visible(false);
        imp.scope_button.set_visible(true);
    }

    fn install_database_action(&self) {
        if self.database_action().is_some() {
            return;
        }
        let action = gio::SimpleAction::new_stateful(SWITCH_ACTION, Some(glib::VariantTy::STRING), &"".to_variant());
        let editor = self.downgrade();
        action.connect_change_state(move |action, value| {
            let (Some(editor), Some(name)) = (editor.upgrade(), value.and_then(|value| value.str())) else {
                return;
            };
            if action.state().as_ref().and_then(|state| state.str()) == Some(name) {
                return;
            }
            action.set_state(&name.to_variant());
            editor.move_to_database(name);
        });
        let group = gio::SimpleActionGroup::new();
        group.add_action(&action);
        self.insert_action_group("tab", Some(&group));
        self.imp().tab_actions.replace(Some(group));
    }

    fn database_action(&self) -> Option<gio::SimpleAction> {
        self.imp()
            .tab_actions
            .borrow()
            .as_ref()?
            .lookup_action(SWITCH_ACTION)
            .and_downcast()
    }

    /// Point the tab at `name`: its sessions run the engine's `USE` before
    /// the next statement, completion resolves unqualified names there,
    /// and the bar names it. The schema goes with the old database, since
    /// a schema only means something inside the database that holds it.
    pub(crate) fn move_to_database(&self, name: &str) {
        self.imp()
            .slot
            .set_database(Some(TabDatabase { name: name.to_owned() }));
        if let Some(action) = self.database_action() {
            action.set_state(&name.to_variant());
        }
        for provider in self.imp().completion_providers.borrow().iter() {
            if let Some(catalog) = provider.downcast_ref::<super::completion::SqlCompletionProvider>() {
                catalog.set_home(Some(name.to_owned()));
            }
        }
        self.set_scope(scope_text(Some(name), None));
        self.emit_by_name::<()>("database-moved", &[&name.to_owned()]);
    }

    /// Completion reads `session`'s catalog: the session the window holds
    /// for the tab's database, once it has opened (0030).
    pub(crate) fn follow_catalog(&self, session: Option<Arc<Session>>) {
        for provider in self.imp().completion_providers.borrow().iter() {
            if let Some(catalog) = provider.downcast_ref::<super::completion::SqlCompletionProvider>() {
                catalog.set_catalog_session(session.clone());
            }
        }
    }

    /// The database the editor bar moved the tab to, which a restore
    /// moves it to again.
    pub(crate) fn tab_database(&self) -> Option<String> {
        self.imp().slot.database().map(|database| database.name)
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
        imp.scope_button
            .update_property(&[gtk4::accessible::Property::Description(&gettext("Switch Database"))]);
        imp.scope_button.set_tooltip_text(Some(&gettext("Switch Database")));
        imp.scope_box.set_visible(!switchable);
        imp.scope_button.set_visible(switchable);
    }
}

#[cfg(test)]
mod tests {
    use gtk4::gio;
    use gtk4::prelude::*;
    use tablepro_core::meta::SchemaInfo;

    use super::{database_menu, scope_text};

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
}
