use relm4::adw::prelude::*;
use relm4::factory::{DynamicIndex, FactoryComponent, FactorySender};
use relm4::gtk::gio;
use relm4::{adw, gtk};
use uuid::Uuid;

use tablepro_core::AuthMode;
use tablepro_storage::{ConnectionColor, SavedConnection};

/// What a row needs to build itself: the connection, plus the groups
/// the rest of the list is filed under so its menu can offer them.
#[derive(Debug, Clone)]
pub struct ConnectionRowInit {
    pub saved: SavedConnection,
    pub groups: Vec<String>,
}

#[derive(Debug)]
pub struct ConnectionRow {
    saved: SavedConnection,
    groups: Vec<String>,
    /// AdwActionRow root widget. Cached so the trash button's
    /// confirmation dialog can `present()` against it (the dialog
    /// walks up to find the GtkWindow, but it needs *some* widget
    /// in the tree to start from).
    root: Option<gtk::Widget>,
}

#[derive(Debug)]
pub enum ConnectionRowMsg {
    Open,
    /// Trash button pressed. Triggers a confirmation dialog before
    /// any actual delete is dispatched — saved connections include
    /// credentials and SSH config and a misclick is unrecoverable.
    RequestDelete,
    /// Copy the connection under a free name, so a second database on
    /// the same server does not have to be typed out again.
    RequestDuplicate,
    /// A colour from the row's own menu, or `None` for the "No colour"
    /// entry.
    SetColor(Option<ConnectionColor>),
    /// A group from the row's own menu, or `None` for "No Group".
    SetGroup(Option<String>),
    /// "New Group…", which asks for a name before filing the
    /// connection under it.
    NewGroupRequested,
}

#[derive(Debug)]
pub enum ConnectionRowOutput {
    Open(SavedConnection),
    Delete(Uuid),
    Duplicate(SavedConnection),
    SetColor(Uuid, Option<ConnectionColor>),
    SetGroup(Uuid, Option<String>),
}

#[relm4::factory(pub)]
impl FactoryComponent for ConnectionRow {
    type Init = ConnectionRowInit;
    type Input = ConnectionRowMsg;
    type Output = ConnectionRowOutput;
    type CommandOutput = ();
    type ParentWidget = gtk::ListBox;

    view! {
        adw::ActionRow {
            set_title: &self.saved.name,
            set_subtitle: &subtitle_for(&self.saved),
            set_activatable: true,
            connect_activated => ConnectionRowMsg::Open,

            // The colour the user put on this connection, as a dot
            // ahead of the name. Absent rather than grey when there is
            // no colour, so an untagged list has no decoration in it.
            add_prefix = &gtk::Box {
                set_valign: gtk::Align::Center,
                add_css_class: "tp-connection-tag",
                set_visible: self.saved.color.is_some(),
                set_css_classes: &tag_classes(self.saved.color),
                set_tooltip_text: color_label(self.saved.color).as_deref(),
            },

            // One menu rather than a button per action: the row gains
            // actions as the app does, and a row of icons stops
            // reading as a row.
            add_suffix = &gtk::MenuButton {
                set_icon_name: crate::ui::icons::VIEW_MORE,
                set_valign: gtk::Align::Center,
                set_tooltip_text: Some(crate::i18n::gettext("Connection options").as_str()),
                add_css_class: "flat",
                set_menu_model: Some(&row_menu(&self.groups)),
            },
        }
    }

    fn init_model(init: Self::Init, _index: &DynamicIndex, _sender: FactorySender<Self>) -> Self {
        Self {
            saved: init.saved,
            groups: init.groups,
            root: None,
        }
    }

    fn init_widgets(
        &mut self,
        _index: &DynamicIndex,
        root: Self::Root,
        _returned_widget: &<Self::ParentWidget as relm4::factory::FactoryView>::ReturnedWidget,
        sender: FactorySender<Self>,
    ) -> Self::Widgets {
        let widgets = view_output!();
        // Stash for the destructive-confirm dialog in update().
        self.root = Some(root.clone().upcast::<gtk::Widget>());

        // Each row owns its actions, so the menu on one row cannot
        // act on another.
        let actions = gio::SimpleActionGroup::new();
        let duplicate_sender = sender.clone();
        let duplicate = gio::ActionEntry::builder("duplicate")
            .activate(move |_, _, _| duplicate_sender.input(ConnectionRowMsg::RequestDuplicate))
            .build();
        let remove_sender = sender.clone();
        let remove = gio::ActionEntry::builder("remove")
            .activate(move |_, _, _| remove_sender.input(ConnectionRowMsg::RequestDelete))
            .build();
        actions.add_action_entries([duplicate, remove]);

        // One stateful action rather than one action per colour, so the
        // menu renders as a radio group with the current colour ticked.
        let color_sender = sender.clone();
        let color = gio::SimpleAction::new_stateful(
            "color",
            Some(&String::static_variant_type()),
            &color_state(self.saved.color).to_variant(),
        );
        color.connect_activate(move |action, parameter| {
            let Some(id) = parameter.and_then(|value| value.get::<String>()) else {
                return;
            };
            action.set_state(&id.to_variant());
            color_sender.input(ConnectionRowMsg::SetColor(ConnectionColor::from_id(&id)));
        });
        actions.add_action(&color);

        // The same radio shape as the colour, over a set of names that
        // comes from the list rather than from a fixed vocabulary.
        let group_sender = sender.clone();
        let group = gio::SimpleAction::new_stateful(
            "group",
            Some(&String::static_variant_type()),
            &self.saved.group.clone().unwrap_or_default().to_variant(),
        );
        group.connect_activate(move |action, parameter| {
            let Some(name) = parameter.and_then(|value| value.get::<String>()) else {
                return;
            };
            action.set_state(&name.to_variant());
            group_sender.input(ConnectionRowMsg::SetGroup(match name.trim().is_empty() {
                true => None,
                false => Some(name),
            }));
        });
        actions.add_action(&group);
        let new_group_sender = sender.clone();
        let new_group = gio::ActionEntry::builder("new-group")
            .activate(move |_, _, _| new_group_sender.input(ConnectionRowMsg::NewGroupRequested))
            .build();
        actions.add_action_entries([new_group]);
        root.insert_action_group("connection", Some(&actions));

        widgets
    }

    fn update(&mut self, msg: Self::Input, sender: FactorySender<Self>) {
        match msg {
            ConnectionRowMsg::Open => {
                let _ = sender.output(ConnectionRowOutput::Open(self.saved.clone()));
            }
            ConnectionRowMsg::RequestDuplicate => {
                let _ = sender.output(ConnectionRowOutput::Duplicate(self.saved.clone()));
            }
            ConnectionRowMsg::SetColor(color) => {
                let _ = sender.output(ConnectionRowOutput::SetColor(self.saved.id, color));
            }
            ConnectionRowMsg::SetGroup(group) => {
                let _ = sender.output(ConnectionRowOutput::SetGroup(self.saved.id, group));
            }
            ConnectionRowMsg::NewGroupRequested => {
                let dialog = adw::AlertDialog::new(Some(&crate::i18n::gettext("New Group")), None);
                let entry = adw::EntryRow::builder().title(crate::i18n::gettext("Name")).build();
                let group = adw::PreferencesGroup::new();
                group.add(&entry);
                dialog.set_extra_child(Some(&group));
                dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
                dialog.add_response("add", &crate::i18n::gettext("Add"));
                dialog.set_response_appearance("add", adw::ResponseAppearance::Suggested);
                dialog.set_default_response(Some("add"));
                dialog.set_close_response("cancel");
                let id = self.saved.id;
                let output = sender.output_sender().clone();
                dialog.connect_response(None, move |dlg, response| {
                    dlg.close();
                    if response != "add" {
                        return;
                    }
                    let name = entry.text().to_string();
                    if name.trim().is_empty() {
                        return;
                    }
                    let _ = output.send(ConnectionRowOutput::SetGroup(id, Some(name)));
                });
                dialog.present(self.root.as_ref());
            }
            ConnectionRowMsg::RequestDelete => {
                // GNOME HIG: destructive actions need explicit
                // confirmation. AdwAlertDialog with a destructive-
                // appearance Remove button is the documented pattern;
                // the Cancel default + Esc-cancellable close response
                // make a misclick a no-op. Body copy spells out the
                // blast radius so the user knows what's actually lost.
                let dialog = adw::AlertDialog::new(None, None);
                dialog.set_heading(Some(&crate::i18n::gettext_f(
                    "Remove “{name}”?",
                    &[("name", &self.saved.name)],
                )));
                dialog.set_body(&crate::i18n::gettext("The saved credentials and SSH settings will be deleted from this device. The database itself is unaffected."));
                dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
                dialog.add_response("remove", &crate::i18n::gettext("Remove"));
                dialog.set_response_appearance("remove", adw::ResponseAppearance::Destructive);
                dialog.set_default_response(Some("cancel"));
                dialog.set_close_response("cancel");
                let id = self.saved.id;
                let output = sender.output_sender().clone();
                dialog.connect_response(None, move |dlg, response| {
                    dlg.close();
                    if response == "remove" {
                        let _ = output.send(ConnectionRowOutput::Delete(id));
                    }
                });
                dialog.present(self.root.as_ref());
            }
        }
    }
}

fn subtitle_for(saved: &SavedConnection) -> String {
    if saved.driver_id == "sqlite" {
        return format!("sqlite · {}", saved.database);
    }
    match saved.auth_mode {
        AuthMode::Kerberos => format!("{} · {}:{}", saved.driver_id, saved.host, saved.port),
        AuthMode::Password => format!("{} · {}@{}:{}", saved.driver_id, saved.username, saved.host, saved.port),
    }
}

/// The row's own menu. Remove sits in its own section so a destructive
/// action is never the neighbour of an ordinary one.
fn row_menu(groups: &[String]) -> gio::Menu {
    let menu = gio::Menu::new();
    menu.append(Some(&crate::i18n::gettext("Duplicate")), Some("connection.duplicate"));
    menu.append_submenu(Some(&crate::i18n::gettext("Colour")), &color_menu());
    menu.append_submenu(Some(&crate::i18n::gettext("Group")), &group_menu(groups));
    let danger = gio::Menu::new();
    danger.append(Some(&crate::i18n::gettext("Remove…")), Some("connection.remove"));
    menu.append_section(None, &danger);
    menu
}

/// The colour choices, as a radio group. "No colour" leads because it
/// is the state every connection starts in.
fn color_menu() -> gio::Menu {
    let menu = gio::Menu::new();
    let clear = gio::MenuItem::new(Some(&crate::i18n::gettext("No Colour")), None);
    clear.set_action_and_target_value(Some("connection.color"), Some(&NO_COLOR.to_variant()));
    menu.append_item(&clear);
    let colors = gio::Menu::new();
    for color in ConnectionColor::ALL {
        let item = gio::MenuItem::new(Some(&color_name(color)), None);
        item.set_action_and_target_value(Some("connection.color"), Some(&color.id().to_variant()));
        colors.append_item(&item);
    }
    menu.append_section(None, &colors);
    menu
}

/// The groups already in the list, as a radio group, with a way to
/// start a new one at the end. A connection whose group is the only
/// one of its kind still appears here, because it is in `groups`.
fn group_menu(groups: &[String]) -> gio::Menu {
    let menu = gio::Menu::new();
    let none = gio::MenuItem::new(Some(&crate::i18n::gettext("No Group")), None);
    none.set_action_and_target_value(Some("connection.group"), Some(&"".to_variant()));
    menu.append_item(&none);
    if !groups.is_empty() {
        let existing = gio::Menu::new();
        for group in groups {
            let item = gio::MenuItem::new(Some(group), None);
            item.set_action_and_target_value(Some("connection.group"), Some(&group.to_variant()));
            existing.append_item(&item);
        }
        menu.append_section(None, &existing);
    }
    let new = gio::Menu::new();
    new.append(Some(&crate::i18n::gettext("New Group…")), Some("connection.new-group"));
    menu.append_section(None, &new);
    menu
}

/// The action state standing for "no colour". An empty string rather
/// than a missing state, because the action's parameter type is a
/// string and a radio group needs every entry to carry one.
const NO_COLOR: &str = "";

fn color_state(color: Option<ConnectionColor>) -> &'static str {
    match color {
        Some(color) => color.id(),
        None => NO_COLOR,
    }
}

fn color_name(color: ConnectionColor) -> String {
    match color {
        ConnectionColor::Blue => crate::i18n::gettext("Blue"),
        ConnectionColor::Teal => crate::i18n::gettext("Teal"),
        ConnectionColor::Green => crate::i18n::gettext("Green"),
        ConnectionColor::Yellow => crate::i18n::gettext("Yellow"),
        ConnectionColor::Orange => crate::i18n::gettext("Orange"),
        ConnectionColor::Red => crate::i18n::gettext("Red"),
        ConnectionColor::Pink => crate::i18n::gettext("Pink"),
        ConnectionColor::Purple => crate::i18n::gettext("Purple"),
        ConnectionColor::Slate => crate::i18n::gettext("Slate"),
    }
}

fn color_label(color: Option<ConnectionColor>) -> Option<String> {
    color.map(color_name)
}

/// The dot's classes. Set as a whole list rather than added one by one
/// so a colour change never leaves the previous colour's class behind.
fn tag_classes(color: Option<ConnectionColor>) -> Vec<&'static str> {
    let mut classes = vec!["tp-connection-tag"];
    if let Some(color) = color {
        classes.push(match color {
            ConnectionColor::Blue => "tp-tag-blue",
            ConnectionColor::Teal => "tp-tag-teal",
            ConnectionColor::Green => "tp-tag-green",
            ConnectionColor::Yellow => "tp-tag-yellow",
            ConnectionColor::Orange => "tp-tag-orange",
            ConnectionColor::Red => "tp-tag-red",
            ConnectionColor::Pink => "tp-tag-pink",
            ConnectionColor::Purple => "tp-tag-purple",
            ConnectionColor::Slate => "tp-tag-slate",
        });
    }
    classes
}

#[cfg(test)]
mod tests {
    use super::*;

    fn saved(username: &str, auth_mode: AuthMode) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: "Corp".into(),
            driver_id: "mssql".into(),
            host: "sql.corp.example".into(),
            port: 1433,
            database: "sales".into(),
            username: username.into(),
            use_tls: true,
            read_only: false,
            auth_mode,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: None,
        }
    }

    /// The labels a menu model carries, in order, for every item and
    /// every section it holds.
    fn menu_labels(menu: &gio::Menu) -> Vec<String> {
        use relm4::gtk::prelude::*;
        let mut labels = Vec::new();
        for index in 0..menu.n_items() {
            if let Some(label) = menu
                .item_attribute_value(index, "label", None)
                .and_then(|v| v.get::<String>())
            {
                labels.push(label);
            }
            if let Some(section) = menu.item_link(index, "section").and_downcast::<gio::Menu>() {
                labels.extend(menu_labels(&section));
            }
        }
        labels
    }

    #[test]
    fn a_kerberos_row_has_no_username_separator_to_dangle() {
        assert_eq!(
            subtitle_for(&saved("", AuthMode::Kerberos)),
            "mssql · sql.corp.example:1433"
        );
        assert_eq!(
            subtitle_for(&saved("sa", AuthMode::Password)),
            "mssql · sa@sql.corp.example:1433"
        );
    }

    #[test]
    fn a_connection_with_no_colour_carries_no_colour_class() {
        assert_eq!(tag_classes(None), vec!["tp-connection-tag"]);
    }

    /// A class with no rule behind it paints nothing, and nothing is
    /// exactly what a missing tag looks like.
    #[test]
    fn every_colour_class_has_a_rule_in_the_stylesheet() {
        let css = include_str!("../../../../data/resources/style.css");

        for color in ConnectionColor::ALL {
            let class = tag_classes(Some(color))[1];
            assert!(
                css.contains(&format!(".tp-connection-tag.{class} {{")),
                "{class} has no rule in style.css"
            );
        }
    }

    #[test]
    fn every_colour_has_a_class_of_its_own() {
        let classes: std::collections::HashSet<&str> = ConnectionColor::ALL
            .into_iter()
            .map(|color| tag_classes(Some(color))[1])
            .collect();

        assert_eq!(classes.len(), ConnectionColor::ALL.len());
    }

    #[test]
    fn the_radio_state_tells_no_colour_apart_from_a_colour() {
        assert_eq!(color_state(None), "");
        assert_eq!(color_state(Some(ConnectionColor::Red)), "red");
        assert_eq!(
            ConnectionColor::from_id(color_state(Some(ConnectionColor::Red))),
            Some(ConnectionColor::Red)
        );
    }

    #[test]
    fn the_group_menu_offers_every_group_the_list_already_has() {
        let menu = group_menu(&["Archive".to_owned(), "Work".to_owned()]);

        let labels = menu_labels(&menu);
        assert!(labels.contains(&"Archive".to_owned()), "{labels:?}");
        assert!(labels.contains(&"Work".to_owned()), "{labels:?}");
    }

    #[test]
    fn the_group_menu_always_offers_no_group_and_a_new_one() {
        let labels = menu_labels(&group_menu(&[]));

        assert_eq!(labels.first().map(String::as_str), Some("No Group"));
        assert_eq!(labels.last().map(String::as_str), Some("New Group…"));
    }
}
