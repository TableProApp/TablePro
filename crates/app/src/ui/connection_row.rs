use relm4::adw::prelude::*;
use relm4::factory::{DynamicIndex, FactoryComponent, FactorySender};
use relm4::{adw, gtk};
use uuid::Uuid;

use tablepro_core::{AuthMode, Environment};
use tablepro_storage::{ConnectionOrganization, SavedConnection};

/// What a row needs to render: the saved record plus its organisation
/// entry. The two live in different files on disk, so the parent hands
/// them down together rather than the row reaching for either.
#[derive(Debug, Clone)]
pub struct ConnectionRowInit {
    pub saved: SavedConnection,
    pub organization: ConnectionOrganization,
}

#[derive(Debug)]
pub struct ConnectionRow {
    saved: SavedConnection,
    organization: ConnectionOrganization,
    /// AdwActionRow root widget. Cached so the trash button's
    /// confirmation dialog can `present()` against it (the dialog
    /// walks up to find the GtkWindow, but it needs *some* widget
    /// in the tree to start from).
    root: Option<gtk::Widget>,
}

#[derive(Debug)]
pub enum ConnectionRowMsg {
    Open,
    ToggleFavorite,
    Organize,
    Edit,
    Duplicate,
    /// Trash button pressed. Triggers a confirmation dialog before
    /// any actual delete is dispatched — saved connections include
    /// credentials and SSH config and a misclick is unrecoverable.
    RequestDelete,
}

#[derive(Debug)]
#[allow(clippy::large_enum_variant)]
pub enum ConnectionRowOutput {
    Open(SavedConnection),
    ToggleFavorite(Uuid),
    Organize(SavedConnection),
    Edit(SavedConnection),
    Duplicate(Uuid),
    Delete(Uuid),
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
            set_subtitle: &subtitle_for(&self.saved, &self.organization),
            set_activatable: true,
            connect_activated => ConnectionRowMsg::Open,

            add_prefix = &gtk::Box {
                set_valign: gtk::Align::Center,
                set_hexpand: false,
                set_width_request: 10,
                set_visible: color_css_class(&self.organization).is_some(),
                set_css_classes: &color_classes(&self.organization),
                set_tooltip_text: self.organization.color.as_deref(),
            },

            add_prefix = &gtk::Box {
                add_css_class: "tp-env-swatch",
                add_css_class: environment_css_class(self.saved.environment),
                set_valign: gtk::Align::Fill,
                set_hexpand: false,
                set_width_request: 6,
                set_tooltip_text: Some(self.saved.environment.display_name()),
            },

            add_prefix = &gtk::Button {
                set_icon_name: if self.organization.favorite {
                    "starred-symbolic"
                } else {
                    "non-starred-symbolic"
                },
                set_valign: gtk::Align::Center,
                set_tooltip_text: Some(if self.organization.favorite {
                    crate::tr!("Remove from favourites")
                } else {
                    crate::tr!("Add to favourites")
                }.as_str()),
                add_css_class: "flat",
                connect_clicked => ConnectionRowMsg::ToggleFavorite,
            },

            add_suffix = &gtk::Button {
                set_icon_name: "view-list-bullet-symbolic",
                set_valign: gtk::Align::Center,
                set_tooltip_text: Some(crate::tr!("Group and tags").as_str()),
                add_css_class: "flat",
                connect_clicked => ConnectionRowMsg::Organize,
            },

            add_suffix = &gtk::Button {
                set_icon_name: "document-edit-symbolic",
                set_valign: gtk::Align::Center,
                set_tooltip_text: Some(crate::tr!("Edit connection").as_str()),
                add_css_class: "flat",
                connect_clicked => ConnectionRowMsg::Edit,
            },

            add_suffix = &gtk::Button {
                set_icon_name: "edit-copy-symbolic",
                set_valign: gtk::Align::Center,
                set_tooltip_text: Some(crate::tr!("Duplicate connection").as_str()),
                add_css_class: "flat",
                connect_clicked => ConnectionRowMsg::Duplicate,
            },

            add_suffix = &gtk::Button {
                set_icon_name: "go-next-symbolic",
                set_valign: gtk::Align::Center,
                set_tooltip_text: Some(crate::tr!("Open connection").as_str()),
                add_css_class: "flat",
                connect_clicked => ConnectionRowMsg::Open,
            },

            add_suffix = &gtk::Button {
                set_icon_name: "user-trash-symbolic",
                set_valign: gtk::Align::Center,
                set_tooltip_text: Some(crate::tr!("Remove connection").as_str()),
                add_css_class: "flat",
                add_css_class: "destructive-action",
                connect_clicked => ConnectionRowMsg::RequestDelete,
            },
        }
    }

    fn init_model(init: Self::Init, _index: &DynamicIndex, _sender: FactorySender<Self>) -> Self {
        Self {
            saved: init.saved,
            organization: init.organization,
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
        widgets
    }

    fn update(&mut self, msg: Self::Input, sender: FactorySender<Self>) {
        match msg {
            ConnectionRowMsg::Open => {
                let _ = sender.output(ConnectionRowOutput::Open(self.saved.clone()));
            }
            ConnectionRowMsg::ToggleFavorite => {
                let _ = sender.output(ConnectionRowOutput::ToggleFavorite(self.saved.id));
            }
            ConnectionRowMsg::Organize => {
                let _ = sender.output(ConnectionRowOutput::Organize(self.saved.clone()));
            }
            ConnectionRowMsg::Edit => {
                let _ = sender.output(ConnectionRowOutput::Edit(self.saved.clone()));
            }
            ConnectionRowMsg::Duplicate => {
                let _ = sender.output(ConnectionRowOutput::Duplicate(self.saved.id));
            }
            ConnectionRowMsg::RequestDelete => {
                // GNOME HIG: destructive actions need explicit
                // confirmation. AdwAlertDialog with a destructive-
                // appearance Remove button is the documented pattern;
                // the Cancel default + Esc-cancellable close response
                // make a misclick a no-op. Body copy spells out the
                // blast radius so the user knows what's actually lost.
                let dialog = adw::AlertDialog::new(None, None);
                dialog.set_heading(Some(
                    &crate::tr!("Remove “{name}”?").replace("{name}", &self.saved.name),
                ));
                dialog.set_body(&crate::tr!(
                    "The saved credentials and SSH settings will be deleted from this device. The database itself is unaffected."
                ));
                dialog.add_response("cancel", &crate::tr!("Cancel"));
                dialog.add_response("remove", &crate::tr!("Remove"));
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

/// The palette class for a row's colour tag, or `None` when it has no
/// colour or one outside the palette.
fn color_css_class(organization: &ConnectionOrganization) -> Option<&'static str> {
    organization
        .color
        .as_deref()
        .and_then(tablepro_storage::connection_color_css_class)
}

fn color_classes(organization: &ConnectionOrganization) -> Vec<&'static str> {
    let mut classes = vec!["tp-color-swatch"];
    classes.extend(color_css_class(organization));
    classes
}

pub(crate) fn environment_css_class(environment: Environment) -> &'static str {
    match environment {
        Environment::Local => "tp-env-local",
        Environment::Dev => "tp-env-dev",
        Environment::Staging => "tp-env-staging",
        Environment::Prod => "tp-env-prod",
    }
}

fn subtitle_for(saved: &SavedConnection, organization: &ConnectionOrganization) -> String {
    let mut subtitle = endpoint_for(saved);
    if let Some(group) = organization.group.as_deref() {
        subtitle.push_str(" · ");
        subtitle.push_str(group);
    }
    if !organization.tags.is_empty() {
        subtitle.push_str(" · ");
        subtitle.push_str(&organization.tags.join(", "));
    }
    subtitle
}

fn endpoint_for(saved: &SavedConnection) -> String {
    if saved.driver_id == "sqlite" {
        return format!("sqlite · {}", saved.database);
    }
    if let Some(directory) = &saved.socket_dir {
        return format!(
            "{} · {}@{}/.s.PGSQL.{}",
            saved.driver_id,
            saved.username,
            directory.display(),
            saved.port
        );
    }
    match saved.auth_mode {
        AuthMode::Kerberos => format!("{} · {}:{}", saved.driver_id, saved.host, saved.port),
        AuthMode::Password => format!("{} · {}@{}:{}", saved.driver_id, saved.username, saved.host, saved.port),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::{Environment, TlsMode};

    fn saved(username: &str, auth_mode: AuthMode) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: "Corp".into(),
            driver_id: "mssql".into(),
            host: "sql.corp.example".into(),
            port: 1433,
            socket_dir: None,
            database: "sales".into(),
            username: username.into(),
            use_tls: true,
            tls_mode: Some(TlsMode::VerifyFull),
            tls_root_cert: None,
            tls_client_cert: None,
            tls_client_key: None,
            auth_mode,
            read_only: false,
            environment: Environment::Prod,
            ssh: None,
            last_opened_at: None,
            connect_timeout_secs: None,
            query_timeout_secs: None,
        }
    }

    fn plain() -> ConnectionOrganization {
        ConnectionOrganization::default()
    }

    #[test]
    fn kerberos_rows_hide_the_username_separator() {
        assert_eq!(
            subtitle_for(&saved("", AuthMode::Kerberos), &plain()),
            "mssql · sql.corp.example:1433"
        );
        assert_eq!(
            subtitle_for(&saved("sa", AuthMode::Password), &plain()),
            "mssql · sa@sql.corp.example:1433"
        );
    }

    #[test]
    fn a_group_and_tags_extend_the_subtitle() {
        let organization = ConnectionOrganization::new(Some("Production"), &["billing".into(), "audit".into()], false)
            .expect("valid organization");
        assert_eq!(
            subtitle_for(&saved("sa", AuthMode::Password), &organization),
            "mssql · sa@sql.corp.example:1433 · Production · audit, billing"
        );
    }

    #[test]
    fn an_unorganized_connection_keeps_the_bare_endpoint_subtitle() {
        assert_eq!(
            subtitle_for(&saved("sa", AuthMode::Password), &plain()),
            endpoint_for(&saved("sa", AuthMode::Password))
        );
    }

    #[test]
    fn a_palette_colour_adds_its_class_to_the_swatch() {
        let organization = ConnectionOrganization::default().with_color(Some("teal"));
        assert_eq!(color_css_class(&organization), Some("tp-color-teal"));
        assert_eq!(color_classes(&organization), vec!["tp-color-swatch", "tp-color-teal"]);
    }

    #[test]
    fn an_uncoloured_row_carries_only_the_swatch_class() {
        let organization = ConnectionOrganization::default();
        assert_eq!(color_css_class(&organization), None);
        assert_eq!(color_classes(&organization), vec!["tp-color-swatch"]);
    }

    #[test]
    fn a_colour_outside_the_palette_never_reaches_a_css_class() {
        let mut organization = ConnectionOrganization::default();
        organization.color = Some("red; background: url(x)".into());
        assert_eq!(color_css_class(&organization), None);
        assert_eq!(color_classes(&organization), vec!["tp-color-swatch"]);
    }

    #[test]
    fn each_environment_has_its_own_colour_class() {
        assert_eq!(environment_css_class(Environment::Local), "tp-env-local");
        assert_eq!(environment_css_class(Environment::Dev), "tp-env-dev");
        assert_eq!(environment_css_class(Environment::Staging), "tp-env-staging");
        assert_eq!(environment_css_class(Environment::Prod), "tp-env-prod");
    }
}
