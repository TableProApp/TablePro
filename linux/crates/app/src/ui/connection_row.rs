use relm4::adw::prelude::*;
use relm4::factory::{DynamicIndex, FactoryComponent, FactorySender};
use relm4::gtk::gio;
use relm4::{adw, gtk};
use uuid::Uuid;

use tablepro_core::AuthMode;
use tablepro_storage::SavedConnection;

#[derive(Debug)]
pub struct ConnectionRow {
    saved: SavedConnection,
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
}

#[derive(Debug)]
pub enum ConnectionRowOutput {
    Open(SavedConnection),
    Delete(Uuid),
    Duplicate(SavedConnection),
}

#[relm4::factory(pub)]
impl FactoryComponent for ConnectionRow {
    type Init = SavedConnection;
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

            // One menu rather than a button per action: the row gains
            // actions as the app does, and a row of icons stops
            // reading as a row.
            add_suffix = &gtk::MenuButton {
                set_icon_name: crate::ui::icons::VIEW_MORE,
                set_valign: gtk::Align::Center,
                set_tooltip_text: Some(crate::i18n::gettext("Connection options").as_str()),
                add_css_class: "flat",
                set_menu_model: Some(&row_menu()),
            },
        }
    }

    fn init_model(saved: Self::Init, _index: &DynamicIndex, _sender: FactorySender<Self>) -> Self {
        Self { saved, root: None }
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
fn row_menu() -> gio::Menu {
    let menu = gio::Menu::new();
    menu.append(Some(&crate::i18n::gettext("Duplicate")), Some("connection.duplicate"));
    let danger = gio::Menu::new();
    danger.append(Some(&crate::i18n::gettext("Remove…")), Some("connection.remove"));
    menu.append_section(None, &danger);
    menu
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
        }
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
}
