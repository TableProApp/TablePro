use relm4::adw::prelude::*;
use relm4::{ComponentController, ComponentSender, adw, gtk};

use tablepro_storage::{
    CONNECTION_COLORS, ConnectionOrganization, ConnectionOrganizationIndex, MAX_TAGS_PER_CONNECTION, SavedConnection,
};
use uuid::Uuid;

use super::{App, AppMsg};

static ORGANIZATION_FILE_MUTATION: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

impl App {
    pub(super) fn load_connection_organization(&self, sender: ComponentSender<Self>) {
        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    match tablepro_storage::load_organization().await {
                        Ok(index) => sender_clone.input(AppMsg::ConnectionOrganizationLoaded(index)),
                        Err(error) => tracing::warn!(error = %error, "load connection organization failed"),
                    }
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn on_connection_organization_loaded(&mut self, index: ConnectionOrganizationIndex) {
        self.connection_organization = index;
        self.publish_connection_organization();
        self.apply_connection_strip();
    }

    pub(super) fn apply_connection_strip(&self) {
        let Some(tab_bar) = self
            .workspace_tab_view
            .as_ref()
            .and_then(|view| view.parent())
            .and_then(|parent| parent.first_child())
        else {
            return;
        };
        for class in tablepro_storage::CONNECTION_STRIP_CLASSES {
            tab_bar.remove_css_class(class);
        }
        let color = self.connection_id.map(|id| self.connection_organization.get(id).color);
        if let Some(class) = color
            .flatten()
            .as_deref()
            .and_then(tablepro_storage::connection_strip_class)
        {
            tab_bar.add_css_class(class);
        }
    }

    fn publish_connection_organization(&self) {
        let _ = self
            .welcome_view
            .sender()
            .send(crate::ui::welcome_view::WelcomeViewInput::SetOrganization(
                self.connection_organization.clone(),
            ));
    }

    pub(super) fn on_toggle_connection_favorite(&mut self, id: Uuid, sender: ComponentSender<Self>) {
        persist_connection_organization(OrganizationMutation::ToggleFavorite(id), sender);
    }

    pub(super) fn on_set_connection_organization(
        &mut self,
        id: Uuid,
        organization: ConnectionOrganization,
        sender: ComponentSender<Self>,
    ) {
        persist_connection_organization(OrganizationMutation::Set(id, organization), sender);
    }

    /// Prune entries for connections that no longer exist, then write.
    /// Runs after a reload so a delete performed in another window does
    /// not leave the sidecar growing forever.
    pub(super) fn prune_connection_organization(&mut self, sender: ComponentSender<Self>) {
        persist_connection_organization(OrganizationMutation::RetainKnown, sender);
    }

    pub(super) fn on_organize_connection(&self, saved: SavedConnection, sender: ComponentSender<Self>) {
        let current = self.connection_organization.get(saved.id);
        let dialog = adw::AlertDialog::new(
            Some(&crate::tr!("Group and tags")),
            Some(&crate::tr!("Group “{name}” and tag it so it is easy to find.").replace("{name}", &saved.name)),
        );

        let group_row = adw::EntryRow::builder().title(crate::tr!("Group")).build();
        group_row.set_text(current.group.as_deref().unwrap_or_default());
        let tags_row = adw::EntryRow::builder()
            .title(crate::tr!("Tags, separated by commas"))
            .build();
        tags_row.set_text(&current.tags.join(", "));

        let color_labels: Vec<String> = color_choice_labels();
        let color_refs: Vec<&str> = color_labels.iter().map(String::as_str).collect();
        let color_row = adw::ComboRow::builder()
            .title(crate::tr!("Colour"))
            .model(&gtk::StringList::new(&color_refs))
            .build();
        color_row.set_selected(color_choice_index(current.color.as_deref()));

        let list = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .css_classes(["boxed-list"])
            .build();
        list.append(&group_row);
        list.append(&tags_row);
        list.append(&color_row);
        dialog.set_extra_child(Some(&list));
        dialog.add_response("cancel", &crate::tr!("Cancel"));
        dialog.add_response("save", &crate::tr!("Save"));
        dialog.set_response_appearance("save", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("save"));
        dialog.set_close_response("cancel");

        let id = saved.id;
        let favorite = current.favorite;
        let input_sender = sender.input_sender().clone();
        dialog.connect_response(None, move |dlg, response| {
            dlg.close();
            if response != "save" {
                return;
            }
            let tags = split_tags(&tags_row.text());
            let color = color_for_choice(color_row.selected());
            match ConnectionOrganization::new(Some(&group_row.text()), &tags, favorite)
                .map(|organization| organization.with_color(color))
            {
                Ok(organization) => {
                    let _ = input_sender.send(AppMsg::SetConnectionOrganization(id, organization));
                }
                Err(error) => {
                    tracing::warn!(error = %error, "rejected connection organization input");
                    let _ = input_sender.send(AppMsg::ConnectionOrganizationRejected);
                }
            }
        });
        dialog.present(Some(&self.window));
    }

    pub(super) fn on_connection_organization_rejected(&self) {
        self.show_toast(&crate::tr!(
            "A group or tag is too long. Keep each under 64 characters."
        ));
    }

    pub(super) fn on_import_connection_url(&self, sender: ComponentSender<Self>) {
        let dialog = adw::AlertDialog::new(
            Some(&crate::tr!("Import from URL")),
            Some(&crate::tr!(
                "Paste a connection URL such as postgres://user@host:5432/database. A password in the URL is stored in the system keyring, never in the connection file."
            )),
        );
        let url_row = adw::EntryRow::builder().title(crate::tr!("Connection URL")).build();
        let list = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .css_classes(["boxed-list"])
            .build();
        list.append(&url_row);
        dialog.set_extra_child(Some(&list));
        dialog.add_response("cancel", &crate::tr!("Cancel"));
        dialog.add_response("import", &crate::tr!("Import"));
        dialog.set_response_appearance("import", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("import"));
        dialog.set_close_response("cancel");

        let input_sender = sender.input_sender().clone();
        dialog.connect_response(None, move |dlg, response| {
            dlg.close();
            if response != "import" {
                return;
            }
            let _ = input_sender.send(AppMsg::ImportConnectionUrlText(url_row.text().to_string()));
        });
        dialog.present(Some(&self.window));
    }

    /// Parse the pasted URL, then persist off the GTK thread. The parse
    /// itself is synchronous and lives in `tablepro-storage`; only the
    /// file write and the keyring call need a command.
    pub(super) fn on_import_connection_url_text(&self, url: String, sender: ComponentSender<Self>) {
        let parsed = match tablepro_storage::parse_connection_url(&url) {
            Ok(parsed) => parsed,
            Err(error) => {
                tracing::warn!(error = %error, "rejected imported connection URL");
                self.show_toast(&crate::tr!(
                    "That is not a connection URL BookiE can read. Use a form like postgres://user@host:5432/database."
                ));
                return;
            }
        };
        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let connection = parsed.connection;
                    let connection_id = connection.id;
                    let label = connection.name.clone();
                    if let Err(error) = tablepro_storage::save_connections(std::slice::from_ref(&connection)).await {
                        tracing::warn!(error = %error, "saving the imported connection failed");
                        sender_clone.input(AppMsg::ImportConnectionUrlFailed);
                        return;
                    }
                    if let Some(password) = parsed.password
                        && let Err(error) =
                            tablepro_storage::store_password(connection_id, secret(&password), &label).await
                    {
                        tracing::warn!(error = %error, "storing the imported password failed");
                        if let Err(rollback_error) = tablepro_storage::delete_connection(connection_id).await {
                            tracing::warn!(error = %rollback_error, "rolling back imported connection failed");
                        }
                        sender_clone.input(AppMsg::ImportConnectionUrlFailed);
                        return;
                    }
                    sender_clone.input(AppMsg::ImportConnectionUrlSucceeded(label));
                    sender_clone.input(AppMsg::ReloadConnections);
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn on_import_connection_url_succeeded(&self, name: String) {
        self.show_toast(&crate::tr!("Imported “{name}”.").replace("{name}", &name));
    }

    pub(super) fn on_import_connection_url_failed(&self) {
        self.show_toast(&crate::tr!("The imported connection could not be saved."));
    }
}

enum OrganizationMutation {
    ToggleFavorite(Uuid),
    Set(Uuid, ConnectionOrganization),
    RetainKnown,
}

fn persist_connection_organization(mutation: OrganizationMutation, sender: ComponentSender<App>) {
    let sender_clone = sender.clone();
    sender.command(move |_, shutdown| {
        shutdown
            .register(async move {
                let result = async {
                    let _guard = ORGANIZATION_FILE_MUTATION.lock().await;
                    let mut index = tablepro_storage::load_organization().await?;
                    match mutation {
                        OrganizationMutation::ToggleFavorite(id) => {
                            index.set_favorite(id, !index.is_favorite(id))?;
                        }
                        OrganizationMutation::Set(id, organization) => index.set(id, organization)?,
                        OrganizationMutation::RetainKnown => {
                            let connections = tablepro_storage::load_connections().await?;
                            index.retain_known(&connections);
                        }
                    }
                    tablepro_storage::save_organization(&index).await?;
                    Ok::<_, tablepro_storage::StorageError>(index)
                }
                .await;
                match result {
                    Ok(index) => sender_clone.input(AppMsg::ConnectionOrganizationLoaded(index)),
                    Err(error) => {
                        tracing::warn!(error = %error, "connection organization mutation failed");
                        sender_clone.input(AppMsg::ShowToast(crate::tr!("This connection could not be updated.")));
                    }
                }
            })
            .drop_on_shutdown()
    });
}

fn secret(password: &secrecy::SecretString) -> &str {
    use secrecy::ExposeSecret;
    password.expose_secret()
}

/// The picker's rows: "No colour" first, then the fixed palette. The
/// palette is closed, so the row index maps back to a palette entry
/// without any free-form colour string reaching storage.
fn color_choice_labels() -> Vec<String> {
    let mut labels = vec![crate::tr!("No colour")];
    labels.extend(CONNECTION_COLORS.iter().map(|name| crate::tr!(*name)));
    labels
}

fn color_choice_index(color: Option<&str>) -> u32 {
    let Some(color) = color.and_then(tablepro_storage::connection_color) else {
        return 0;
    };
    CONNECTION_COLORS
        .iter()
        .position(|name| *name == color)
        .map_or(0, |index| index as u32 + 1)
}

fn color_for_choice(row: u32) -> Option<&'static str> {
    if row == 0 {
        return None;
    }
    CONNECTION_COLORS.get(row as usize - 1).copied()
}

/// Split a comma-separated tag entry. Empty segments are dropped here so
/// a trailing comma while typing is not an error, and the ceiling keeps
/// a pasted wall of text from reaching the validator as thousands of
/// candidate tags.
fn split_tags(raw: &str) -> Vec<String> {
    raw.split(',')
        .map(str::trim)
        .filter(|tag| !tag.is_empty())
        .take(MAX_TAGS_PER_CONNECTION)
        .map(str::to_owned)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_colour_picker_round_trips_every_palette_entry() {
        assert_eq!(color_choice_index(None), 0);
        assert_eq!(color_for_choice(0), None);
        for (offset, name) in CONNECTION_COLORS.iter().enumerate() {
            let row = offset as u32 + 1;
            assert_eq!(color_for_choice(row), Some(*name));
            assert_eq!(color_choice_index(Some(name)), row);
        }
    }

    #[test]
    fn a_colour_outside_the_palette_selects_no_colour() {
        assert_eq!(color_choice_index(Some("#ff0000")), 0);
        assert_eq!(color_for_choice(CONNECTION_COLORS.len() as u32 + 1), None);
    }

    #[test]
    fn the_picker_offers_no_colour_plus_the_whole_palette() {
        assert_eq!(color_choice_labels().len(), CONNECTION_COLORS.len() + 1);
    }

    #[test]
    fn tag_entry_text_becomes_trimmed_non_empty_tags() {
        assert_eq!(split_tags(" billing , audit ,"), vec!["billing", "audit"]);
        assert_eq!(split_tags(""), Vec::<String>::new());
        assert_eq!(split_tags(" , , "), Vec::<String>::new());
    }

    #[test]
    fn a_pasted_wall_of_tags_is_capped_before_validation() {
        let raw = (0..MAX_TAGS_PER_CONNECTION * 4)
            .map(|i| format!("tag{i}"))
            .collect::<Vec<_>>()
            .join(",");
        assert_eq!(split_tags(&raw).len(), MAX_TAGS_PER_CONNECTION);
    }
}
