use std::time::Duration;

use relm4::adw::prelude::*;
use relm4::{ComponentSender, adw, gtk};
use uuid::Uuid;

use super::{App, AppMsg};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct DatabaseChoice {
    pub name: String,
    pub current: bool,
}

pub(super) fn database_choices(names: &[String], current: &str) -> Vec<DatabaseChoice> {
    let mut choices: Vec<DatabaseChoice> = names
        .iter()
        .map(|name| DatabaseChoice {
            name: name.clone(),
            current: name == current,
        })
        .collect();
    if !current.is_empty() && !choices.iter().any(|choice| choice.current) {
        choices.push(DatabaseChoice {
            name: current.to_string(),
            current: true,
        });
    }
    choices.sort_by_key(|choice| choice.name.to_lowercase());
    choices.dedup_by(|left, right| left.name == right.name);
    choices
}

pub(super) fn build_database_popover(popover: &gtk::Popover, sender: &ComponentSender<App>) -> gtk::ListBox {
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .css_classes(["boxed-list"])
        .build();
    let scroll = gtk::ScrolledWindow::builder()
        .child(&list)
        .min_content_width(280)
        .min_content_height(80)
        .max_content_height(360)
        .propagate_natural_height(true)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .build();
    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .margin_top(6)
        .margin_bottom(6)
        .margin_start(6)
        .margin_end(6)
        .build();
    content.append(&scroll);
    popover.set_child(Some(&content));
    let opened = sender.clone();
    popover.connect_visible_notify(move |popover| {
        if popover.is_visible() {
            opened.input(AppMsg::LoadDatabases);
        }
    });
    list
}

fn clear(list: &gtk::ListBox) {
    while let Some(child) = list.first_child() {
        list.remove(&child);
    }
}

fn choice_button(choice: &DatabaseChoice, sender: &ComponentSender<App>) -> gtk::Button {
    let content = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let label = gtk::Label::builder()
        .label(&choice.name)
        .xalign(0.0)
        .hexpand(true)
        .build();
    content.append(&label);
    if choice.current {
        content.append(&gtk::Image::from_icon_name("object-select-symbolic"));
    }
    let button = gtk::Button::builder().child(&content).css_classes(["flat"]).build();
    button.update_property(&[gtk::accessible::Property::Label(&choice.name)]);
    let picked = sender.clone();
    let name = choice.name.clone();
    button.connect_clicked(move |_| picked.input(AppMsg::SwitchDatabase(name.clone())));
    button
}

fn message_row(title: &str, subtitle: &str) -> adw::ActionRow {
    adw::ActionRow::builder().title(title).subtitle(subtitle).build()
}

impl App {
    pub(super) fn on_load_databases(&self, sender: ComponentSender<Self>) {
        let (Some(id), Some(connection)) = (self.connection_id, self.window_connection()) else {
            return;
        };
        clear(&self.databases_list);
        self.databases_list.append(&message_row(&crate::tr!("Loading…"), ""));
        let timeout = Duration::from_secs(
            crate::services::operation_control::timeout_for(&self.preferences, &self.database, self.connection_id)
                .into(),
        );
        let reply = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let result = match tokio::time::timeout(timeout, connection.list_databases()).await {
                        Ok(Ok(names)) => Ok(names),
                        Ok(Err(error)) => Err(crate::ui::error_text::driver_message(&error)),
                        Err(_) => Err(crate::tr!("Listing databases timed out.")),
                    };
                    reply.input(AppMsg::DatabasesLoaded {
                        connection_id: id,
                        result,
                    });
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn on_databases_loaded(
        &self,
        connection_id: Uuid,
        result: Result<Vec<String>, String>,
        sender: ComponentSender<Self>,
    ) {
        if self.connection_id != Some(connection_id) {
            return;
        }
        clear(&self.databases_list);
        let names = match result {
            Ok(names) => names,
            Err(message) => {
                self.databases_list
                    .append(&message_row(&crate::tr!("Could not list databases"), &message));
                return;
            }
        };
        let current = self
            .saved_connections
            .iter()
            .find(|saved| saved.id == connection_id)
            .map(|saved| saved.database.clone())
            .unwrap_or_default();
        for choice in database_choices(&names, &current) {
            self.databases_list.append(&choice_button(&choice, &sender));
        }
    }

    pub(super) fn on_switch_database(&mut self, name: String, sender: ComponentSender<Self>) {
        self.databases_button.popdown();
        let Some(id) = self.connection_id else {
            return;
        };
        let Some(mut saved) = self.saved_connections.iter().find(|saved| saved.id == id).cloned() else {
            self.show_toast(&crate::tr!(
                "This connection is not saved, so its database cannot be switched."
            ));
            return;
        };
        if saved.database == name {
            return;
        }
        saved.database = name.clone();
        self.pending_database_switch = Some((id, name));
        self.on_open_saved(saved, sender);
    }

    pub(super) fn show_database_switcher(&mut self, driver_id: &str, id: Uuid, sender: &ComponentSender<Self>) {
        self.databases_button.set_visible(
            self.registry
                .get(driver_id)
                .is_some_and(|driver| driver.supports_database_listing()),
        );
        self.persist_switched_database(id, sender);
    }

    fn persist_switched_database(&mut self, id: Uuid, sender: &ComponentSender<Self>) {
        let Some((pending, name)) = self.pending_database_switch.take() else {
            return;
        };
        if pending != id {
            return;
        }
        let reply = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    match tablepro_storage::load_connections().await {
                        Ok(mut saved) => {
                            if let Some(connection) = saved.iter_mut().find(|connection| connection.id == id) {
                                connection.database = name;
                                if let Err(error) =
                                    tablepro_storage::save_connections(std::slice::from_ref(connection)).await
                                {
                                    tracing::warn!(%error, "the switched database was not saved");
                                }
                            }
                        }
                        Err(error) => {
                            tracing::warn!(%error, "saved connections could not be read to keep the database")
                        }
                    }
                    reply.input(AppMsg::ReloadConnections);
                })
                .drop_on_shutdown()
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    #[test]
    fn databases_are_listed_alphabetically_with_the_current_one_marked() {
        let choices = database_choices(&names(&["zeta", "Alpha", "beta"]), "beta");
        assert_eq!(
            choices
                .iter()
                .map(|choice| (choice.name.as_str(), choice.current))
                .collect::<Vec<_>>(),
            vec![("Alpha", false), ("beta", true), ("zeta", false)]
        );
    }

    #[test]
    fn a_current_database_the_server_did_not_list_is_still_shown() {
        let choices = database_choices(&names(&["alpha"]), "hidden_db");
        assert!(
            choices
                .iter()
                .any(|choice| choice.name == "hidden_db" && choice.current)
        );
        assert_eq!(choices.len(), 2);
    }

    #[test]
    fn an_empty_current_name_adds_nothing_and_duplicates_collapse() {
        let choices = database_choices(&names(&["a", "a"]), "");
        assert_eq!(choices.len(), 1);
        assert!(!choices[0].current);
    }
}
