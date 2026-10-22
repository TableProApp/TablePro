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
    actions_button: gtk::MenuButton,
}

#[derive(Debug, Clone)]
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
            set_use_markup: false,
            set_title_lines: 1,
            set_subtitle_lines: 1,
            set_tooltip_text: Some(format!("{}\n{}", self.saved.name, subtitle_for(&self.saved, &self.organization)).as_str()),
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

            add_suffix = &self.actions_button.clone(),

            add_suffix = &gtk::Button {
                set_icon_name: "go-next-symbolic",
                set_valign: gtk::Align::Center,
                set_tooltip_text: Some(crate::tr!("Open connection").as_str()),
                add_css_class: "flat",
                connect_clicked => ConnectionRowMsg::Open,
            },
        }
    }

    fn init_model(init: Self::Init, _index: &DynamicIndex, sender: FactorySender<Self>) -> Self {
        Self {
            saved: init.saved,
            organization: init.organization,
            actions_button: connection_actions(sender),
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
                let _ = sender.output(ConnectionRowOutput::Delete(self.saved.id));
            }
        }
    }
}

fn connection_actions(sender: FactorySender<ConnectionRow>) -> gtk::MenuButton {
    let button = gtk::MenuButton::builder()
        .icon_name("view-more-symbolic")
        .valign(gtk::Align::Center)
        .tooltip_text(crate::tr!("Connection actions"))
        .css_classes(["flat"])
        .build();
    button.update_property(&[gtk::accessible::Property::Label(&crate::tr!("Connection actions"))]);
    let popover = gtk::Popover::new();
    let content = gtk::Box::new(gtk::Orientation::Vertical, 2);
    for (label, message) in [
        (crate::tr!("Group and tags"), ConnectionRowMsg::Organize),
        (crate::tr!("Edit connection"), ConnectionRowMsg::Edit),
        (crate::tr!("Duplicate connection"), ConnectionRowMsg::Duplicate),
        (crate::tr!("Remove connection"), ConnectionRowMsg::RequestDelete),
    ] {
        let action = gtk::Button::with_label(&label);
        action.add_css_class("flat");
        let sender = sender.clone();
        let popover = popover.downgrade();
        action.connect_clicked(move |_| {
            if let Some(popover) = popover.upgrade() {
                popover.popdown();
            }
            sender.input(message.clone());
        });
        content.append(&action);
    }
    popover.set_child(Some(&content));
    button.set_popover(Some(&popover));
    button
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
    if let Some(path) = &saved.socket_path {
        return format!("{} · {}@{}", saved.driver_id, saved.username, path.display());
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
            auth_source: None,
            id: Uuid::new_v4(),
            name: "Corp".into(),
            driver_id: "mssql".into(),
            host: "sql.corp.example".into(),
            port: 1433,
            socket_dir: None,
            socket_path: None,
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
    #[ignore = "requires an isolated GTK display"]
    fn connection_actions_leave_room_for_text_in_a_narrow_row() {
        adw::init().unwrap();
        let list = gtk::ListBox::new();
        let mut factory = relm4::factory::FactoryVecDeque::<ConnectionRow>::builder()
            .launch(list.clone())
            .detach();
        let mut connection = saved("analyst", AuthMode::Password);
        connection.name = "Production analytics connection 東京".into();
        factory.guard().push_back(ConnectionRowInit {
            saved: connection,
            organization: plain(),
        });
        let context = gtk::glib::MainContext::default();
        while context.iteration(false) {}
        let provider = gtk::CssProvider::new();
        provider.load_from_string("* { font-size: 20px; }");
        gtk::style_context_add_provider_for_display(
            &gtk::gdk::Display::default().unwrap(),
            &provider,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
        let minimum = list.measure(gtk::Orientation::Horizontal, -1).0;
        list.allocate(320, 200, -1, None);
        let mut pending = vec![list.clone().upcast::<gtk::Widget>()];
        let mut title_width = None;
        while let Some(widget) = pending.pop() {
            if let Some(label) = widget.downcast_ref::<gtk::Label>()
                && label.text() == "Production analytics connection 東京"
            {
                title_width = Some(label.width());
            }
            let mut child = widget.first_child();
            while let Some(widget) = child {
                child = widget.next_sibling();
                pending.push(widget);
            }
        }
        gtk::style_context_remove_provider_for_display(&gtk::gdk::Display::default().unwrap(), &provider);
        assert!(
            minimum <= 320,
            "connection row requires {minimum}px at larger text size"
        );
        assert!(
            title_width.unwrap() >= 120,
            "connection name only receives {title_width:?} pixels"
        );
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn connection_menu_dispatches_actions_for_its_own_record() {
        adw::init().unwrap();
        let (sender, _receiver) = relm4::channel::<()>();
        let (observed, outputs) = std::sync::mpsc::channel();
        let mut factory = relm4::factory::FactoryVecDeque::<ConnectionRow>::builder()
            .launch(gtk::ListBox::new())
            .forward(&sender, move |output| observed.send(output).unwrap());
        let connection = saved("analyst", AuthMode::Password);
        let id = connection.id;
        factory.guard().push_back(ConnectionRowInit {
            saved: connection,
            organization: plain(),
        });
        let context = gtk::glib::MainContext::default();
        while context.iteration(false) {}
        let button = factory.guard().get(0).unwrap().actions_button.clone();
        let content = button.popover().unwrap().child().unwrap();
        let mut actions = Vec::new();
        let mut child = content.first_child();
        while let Some(widget) = child {
            child = widget.next_sibling();
            actions.push(widget.downcast::<gtk::Button>().unwrap());
        }
        assert_eq!(actions.len(), 4);
        for (expected, action) in actions.iter().take(3).enumerate() {
            action.emit_clicked();
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(1);
            let output = loop {
                while context.iteration(false) {}
                if let Ok(output) = outputs.try_recv() {
                    break output;
                }
                assert!(std::time::Instant::now() < deadline, "connection action did not arrive");
                std::thread::sleep(std::time::Duration::from_millis(1));
            };
            match (expected, output) {
                (0, ConnectionRowOutput::Organize(saved)) | (1, ConnectionRowOutput::Edit(saved)) => {
                    assert_eq!(saved.id, id);
                }
                (2, ConnectionRowOutput::Duplicate(actual)) => assert_eq!(actual, id),
                (_, other) => panic!("unexpected connection action: {other:?}"),
            }
        }
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
