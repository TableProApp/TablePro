//! Which schemas the sidebar lists, as macOS's schema filter does: a menu
//! in the sidebar's bottom bar picks them, and a banner says the list is
//! filtered, since a filtered list looks like a short one. The filter is
//! kept per connection while the window is open.

use std::borrow::Cow;
use std::collections::HashSet;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use tablepro_core::meta::{ObjectInfo, SchemaInfo};

use super::{WorkspaceInput, WorkspaceSender};
use crate::i18n::{gettext, gettext_f};
use crate::runtime::DeliverInput;

pub(super) struct SchemaFilter {
    hidden: Arc<HashSet<String>>,
    button: gtk::MenuButton,
    banner: adw::Banner,
    /// The menu on offer, kept while the schemas stay the same so that
    /// choosing one does not close it.
    menu: Option<Menu>,
}

struct Menu {
    names: Vec<String>,
    checks: Vec<gtk::CheckButton>,
    show_all: gtk::Button,
}

impl SchemaFilter {
    pub(super) fn new(button: gtk::MenuButton, banner: adw::Banner, input: &WorkspaceSender) -> Self {
        let input = input.clone();
        banner.connect_button_clicked(move |_| input.deliver(WorkspaceInput::ShowAllSchemas));
        Self {
            hidden: Arc::default(),
            button,
            banner,
            menu: None,
        }
    }

    pub(super) fn hidden(&self) -> Arc<HashSet<String>> {
        self.hidden.clone()
    }

    /// Hide or list `name`. Whether the filter changed.
    pub(super) fn set_hidden(&mut self, name: &str, hidden: bool) -> bool {
        if self.hidden.contains(name) == hidden {
            return false;
        }
        let set = Arc::make_mut(&mut self.hidden);
        if hidden {
            set.insert(name.to_owned());
        } else {
            set.remove(name);
        }
        true
    }

    /// List every schema again. Whether the filter changed.
    pub(super) fn show_all(&mut self) -> bool {
        let changed = !self.hidden.is_empty();
        self.hidden = Arc::default();
        changed
    }

    /// Name the schemas the connection has: the menu offers them, and the
    /// banner says how many the list shows. One schema has nothing to
    /// filter, and a schema that is gone is not kept hidden.
    pub(super) fn refresh(&mut self, schemas: &[SchemaInfo], input: &WorkspaceSender) {
        if !self.hidden.is_empty() {
            let names: HashSet<&str> = schemas.iter().map(|schema| schema.name.as_str()).collect();
            if self.hidden.iter().any(|name| !names.contains(name.as_str())) {
                Arc::make_mut(&mut self.hidden).retain(|name| names.contains(name.as_str()));
            }
        }
        self.button.set_visible(schemas.len() > 1);
        let names: Vec<String> = schemas.iter().map(|schema| schema.name.clone()).collect();
        if self.menu.as_ref().is_none_or(|menu| menu.names != names) {
            self.menu = Some(self.build_menu(names, input));
        }
        if let Some(menu) = &self.menu {
            for (check, schema) in menu.checks.iter().zip(schemas) {
                check.set_active(!self.hidden.contains(&schema.name));
            }
            menu.show_all.set_sensitive(!self.hidden.is_empty());
        }

        let hidden = schemas
            .iter()
            .filter(|schema| self.hidden.contains(&schema.name))
            .count();
        self.banner.set_revealed(hidden > 0);
        if hidden > 0 {
            self.banner.set_title(&gettext_f(
                "Showing {shown} of {total} schemas",
                &[
                    ("shown", &(schemas.len() - hidden).to_string()),
                    ("total", &schemas.len().to_string()),
                ],
            ));
        }
    }

    fn build_menu(&self, names: Vec<String>, input: &WorkspaceSender) -> Menu {
        let list = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let mut checks = Vec::new();
        for schema in &names {
            let check = gtk::CheckButton::with_label(schema);
            check.set_active(true);
            let (input, name) = (input.clone(), schema.clone());
            check.connect_toggled(move |check| {
                input.deliver(WorkspaceInput::HideSchema {
                    name: name.clone(),
                    hidden: !check.is_active(),
                });
            });
            list.append(&check);
            checks.push(check);
        }
        let scroll = gtk::ScrolledWindow::builder()
            .child(&list)
            .propagate_natural_height(true)
            .max_content_height(320)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .build();
        let show_all = gtk::Button::with_label(&gettext("Show All"));
        show_all.add_css_class("flat");
        let show = input.clone();
        show_all.connect_clicked(move |_| show.deliver(WorkspaceInput::ShowAllSchemas));

        let content = gtk::Box::new(gtk::Orientation::Vertical, 6);
        content.append(&scroll);
        content.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
        content.append(&show_all);
        self.button
            .set_popover(Some(&gtk::Popover::builder().child(&content).build()));
        Menu {
            names,
            checks,
            show_all,
        }
    }
}

/// The objects and schemas the sidebar lists under `hidden`. An object
/// with no schema belongs to the default one.
pub(super) fn listed<'a>(
    hidden: &HashSet<String>,
    objects: &'a [ObjectInfo],
    schemas: &'a [SchemaInfo],
) -> (Cow<'a, [ObjectInfo]>, Cow<'a, [SchemaInfo]>) {
    if hidden.is_empty() {
        return (Cow::Borrowed(objects), Cow::Borrowed(schemas));
    }
    let default = schemas
        .iter()
        .find(|schema| schema.is_default)
        .map(|schema| schema.name.as_str());
    let objects = objects
        .iter()
        .filter(|object| {
            object
                .schema
                .as_deref()
                .or(default)
                .is_none_or(|schema| !hidden.contains(schema))
        })
        .cloned()
        .collect();
    let schemas = schemas
        .iter()
        .filter(|schema| !hidden.contains(&schema.name))
        .cloned()
        .collect();
    (Cow::Owned(objects), Cow::Owned(schemas))
}

#[cfg(test)]
mod tests {
    use tablepro_core::meta::ObjectKind;

    use super::*;

    fn object(schema: Option<&str>, name: &str) -> ObjectInfo {
        ObjectInfo::new(schema.map(str::to_owned), name, ObjectKind::Table)
    }

    fn schema(name: &str, is_default: bool) -> SchemaInfo {
        SchemaInfo {
            name: name.to_owned(),
            is_default,
            is_system: false,
        }
    }

    fn names(objects: &[ObjectInfo]) -> Vec<&str> {
        objects.iter().map(|object| object.name.as_str()).collect()
    }

    #[test]
    fn nothing_hidden_lists_everything_without_a_copy() {
        let (objects, schemas) = (vec![object(Some("a"), "t")], vec![schema("a", true)]);
        let (listed_objects, listed_schemas) = listed(&HashSet::new(), &objects, &schemas);
        assert!(matches!(listed_objects, Cow::Borrowed(_)));
        assert!(matches!(listed_schemas, Cow::Borrowed(_)));
    }

    #[test]
    fn a_hidden_schema_takes_its_objects_and_its_section_with_it() {
        let objects = vec![
            object(Some("a"), "one"),
            object(Some("b"), "two"),
            object(None, "three"),
        ];
        let schemas = vec![schema("a", true), schema("b", false)];

        let (shown, kept) = listed(&HashSet::from(["b".to_owned()]), &objects, &schemas);
        assert_eq!(names(&shown), ["one", "three"]);
        assert_eq!(kept.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(), ["a"]);

        let (shown, _) = listed(&HashSet::from(["a".to_owned()]), &objects, &schemas);
        assert_eq!(names(&shown), ["two"], "an object with no schema is the default's");
    }
}
