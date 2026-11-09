use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use tablepro_core::meta::SchemaInfo;

use super::schema_filter::SchemaFilter;
use super::{WorkspaceInput, WorkspaceModel, WorkspaceSender};
use crate::i18n::{gettext, ngettext_f};
use crate::runtime::DeliverInput;

pub(crate) struct SchemaChoices {
    schemas: Arc<[SchemaInfo]>,
    filter: SchemaFilter,
    // Where the schemas are the server's databases, the user knows them as databases.
    databases: bool,
}

impl SchemaChoices {
    fn summary(&self) -> String {
        match self.filter.summary(&self.schemas) {
            Some((shown, total)) => showing(self.databases, shown, total),
            None if self.databases => gettext("Showing all databases"),
            None => gettext("Showing all schemas"),
        }
    }
}

fn showing(databases: bool, shown: usize, total: usize) -> String {
    let (shown, count) = (shown.to_string(), total.to_string());
    let args = [("shown", shown.as_str()), ("total", count.as_str())];
    if databases {
        ngettext_f(
            "Showing {shown} of {total} database",
            "Showing {shown} of {total} databases",
            total,
            &args,
        )
    } else {
        ngettext_f(
            "Showing {shown} of {total} schema",
            "Showing {shown} of {total} schemas",
            total,
            &args,
        )
    }
}

impl WorkspaceModel {
    pub(super) fn schema_choices(&self) -> SchemaChoices {
        SchemaChoices {
            schemas: self.catalog_schemas.clone(),
            filter: self.schema_filter.clone(),
            databases: self.sidebar.affordances().lists_databases,
        }
    }

    pub(super) fn on_schema_shown(&mut self, name: &str, shown: bool) {
        if self.schema_filter.set_shown(&self.catalog_schemas, name, shown) {
            self.keep_schema_filter();
        }
    }

    pub(super) fn on_all_schemas_shown(&mut self) {
        if self.schema_filter.show_all() {
            self.keep_schema_filter();
        }
    }

    fn keep_schema_filter(&mut self) {
        if let Some(session) = self.context.active.get() {
            self.storage.filter_settings().set_sidebar_schemas(
                session.metadata().id,
                session.database().unwrap_or_default(),
                self.schema_filter.kept(),
            );
        }
        self.show_schema_filter();
        self.read_sidebar(self.sidebar_objects.clone());
    }

    // A filtered list looks like a short one, so the banner says it is filtered.
    pub(super) fn show_schema_filter(&self) {
        let choices = self.schema_choices();
        let offered = self.keys.is_none() && choices.schemas.len() > 1;
        let summary = choices.filter.summary(&choices.schemas).filter(|_| offered);
        if let Some((shown, total)) = summary {
            self.schema_filter_banner
                .set_title(&showing(choices.databases, shown, total));
        }
        self.schema_filter_banner.set_revealed(summary.is_some());
        let label = match (offered, choices.databases) {
            (false, _) => String::new(),
            (true, true) => gettext("Databases"),
            (true, false) => gettext("Schemas"),
        };
        if let Some(workspace) = self.this.upgrade() {
            workspace.show_schema_filter_label(label);
        }
    }
}

struct Chooser {
    choices: RefCell<SchemaChoices>,
    input: WorkspaceSender,
    names: gtk::StringList,
    // Weak, since the widgets' handlers hold the chooser.
    summary: glib::WeakRef<gtk::Label>,
    show_all: glib::WeakRef<gtk::Button>,
}

impl Chooser {
    fn toggle(self: &Rc<Self>, name: &str, shown: bool) {
        let changed = {
            let mut choices = self.choices.borrow_mut();
            let SchemaChoices { schemas, filter, .. } = &mut *choices;
            filter.set_shown(schemas, name, shown)
        };
        if changed {
            self.input.deliver(WorkspaceInput::ShowSchema {
                name: name.to_owned(),
                shown,
            });
        }
        self.refresh();
    }

    fn show_all(self: &Rc<Self>) {
        if self.choices.borrow_mut().filter.show_all() {
            self.input.deliver(WorkspaceInput::ShowAllSchemas);
        }
        self.refresh();
    }

    // Rebound from idle: a toggle or a refused hide must not rebind the row
    // that is still emitting its signal.
    fn refresh(self: &Rc<Self>) {
        self.show_summary();
        let chooser = Rc::downgrade(self);
        glib::idle_add_local_once(move || {
            if let Some(chooser) = chooser.upgrade() {
                let names = chooser.names.n_items();
                let listed: Vec<String> = chooser
                    .choices
                    .borrow()
                    .schemas
                    .iter()
                    .map(|schema| schema.name.clone())
                    .collect();
                let listed: Vec<&str> = listed.iter().map(String::as_str).collect();
                chooser.names.splice(0, names, &listed);
            }
        });
    }

    fn show_summary(&self) {
        let choices = self.choices.borrow();
        if let Some(summary) = self.summary.upgrade() {
            summary.set_label(&choices.summary());
        }
        if let Some(show_all) = self.show_all.upgrade() {
            show_all.set_sensitive(choices.filter.summary(&choices.schemas).is_some());
        }
    }
}

// Built each time it opens, so it lists the schemas of the session in front as they are then.
pub(crate) fn popover(choices: SchemaChoices, input: WorkspaceSender) -> gtk::Popover {
    let databases = choices.databases;
    let names = gtk::StringList::new(
        &choices
            .schemas
            .iter()
            .map(|schema| schema.name.as_str())
            .collect::<Vec<_>>(),
    );
    let summary = gtk::Label::builder()
        .xalign(0.0)
        .hexpand(true)
        .ellipsize(gtk::pango::EllipsizeMode::End)
        .css_classes(["caption", "dimmed"])
        .build();
    let show_all = gtk::Button::builder()
        .label(gettext("Show _All"))
        .use_underline(true)
        .css_classes(["flat"])
        .build();
    let chooser = Rc::new(Chooser {
        choices: RefCell::new(choices),
        input,
        names: names.clone(),
        summary: summary.downgrade(),
        show_all: show_all.downgrade(),
    });
    chooser.show_summary();
    show_all.connect_clicked(glib::clone!(
        #[strong]
        chooser,
        move |_| chooser.show_all()
    ));

    let searching = if databases {
        gettext("Search databases")
    } else {
        gettext("Search schemas")
    };
    let search = gtk::SearchEntry::builder().placeholder_text(&searching).build();
    search.update_property(&[gtk::accessible::Property::Label(&searching)]);
    let filter = gtk::StringFilter::builder()
        .expression(gtk::PropertyExpression::new(
            gtk::StringObject::static_type(),
            None::<gtk::Expression>,
            "string",
        ))
        .ignore_case(true)
        .match_mode(gtk::StringFilterMatchMode::Substring)
        .build();
    search.connect_search_changed(glib::clone!(
        #[weak]
        filter,
        move |search| filter.set_search(Some(&search.text()))
    ));

    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(glib::clone!(
        #[strong]
        chooser,
        move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            // The check takes the focus, so Space toggles it and the arrows move between rows.
            item.set_focusable(false);
            item.set_activatable(false);
            let check = gtk::CheckButton::new();
            check.connect_toggled(glib::clone!(
                #[strong]
                chooser,
                move |check| {
                    let Some(name) = check.label() else {
                        return;
                    };
                    let shown = chooser.choices.borrow().shows(&name);
                    if check.is_active() != shown {
                        chooser.toggle(&name, check.is_active());
                    }
                }
            ));
            item.set_child(Some(&check));
        }
    ));
    factory.connect_bind(glib::clone!(
        #[strong]
        chooser,
        move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            let (Some(check), Some(name)) = (
                item.child().and_downcast::<gtk::CheckButton>(),
                item.item().and_downcast::<gtk::StringObject>(),
            ) else {
                return;
            };
            let name = name.string();
            let choices = chooser.choices.borrow();
            let shows = choices.shows(&name);
            check.set_label(Some(&name));
            check.set_active(shows);
            // The last schema listed stays listed.
            let last = shows
                && choices
                    .filter
                    .summary(&choices.schemas)
                    .is_some_and(|(shown, _)| shown == 1);
            check.set_sensitive(!last);
        }
    ));
    let list = gtk::ListView::builder()
        .model(&gtk::NoSelection::new(Some(gtk::FilterListModel::new(
            Some(names),
            Some(filter),
        ))))
        .factory(&factory)
        .build();
    let scrolled = gtk::ScrolledWindow::builder()
        .child(&list)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .propagate_natural_height(true)
        .max_content_height(320)
        .min_content_width(240)
        .build();

    let footer = gtk::Box::builder().spacing(12).build();
    footer.append(&summary);
    footer.append(&show_all);
    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(6)
        .build();
    content.append(&search);
    content.append(&scrolled);
    content.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    content.append(&footer);
    gtk::Popover::builder().child(&content).build()
}

impl SchemaChoices {
    fn shows(&self, name: &str) -> bool {
        self.filter.shows(&self.schemas, name)
    }
}
