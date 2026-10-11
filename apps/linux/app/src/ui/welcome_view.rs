use relm4::adw::prelude::*;
use relm4::factory::FactoryVecDeque;
use relm4::prelude::*;
use relm4::{adw, gtk};

use tablepro_storage::{ConnectionOrganizationIndex, SavedConnection, arrange_connections};
use uuid::Uuid;

use super::connection_row::{ConnectionRow, ConnectionRowInit, ConnectionRowOutput};

pub struct WelcomeView {
    connections: Vec<SavedConnection>,
    organization: ConnectionOrganizationIndex,
    filter: String,
    /// One factory per rendered group. A `FactoryVecDeque` owns exactly
    /// one list box, so a per-group section needs its own factory; the
    /// vector is rebuilt whenever the arrangement changes.
    sections: Vec<FactoryVecDeque<ConnectionRow>>,
    sections_box: gtk::Box,
    stack: gtk::Stack,
    search: gtk::SearchEntry,
    empty_filter_page: adw::StatusPage,
}

#[derive(Debug)]
#[allow(clippy::large_enum_variant)]
pub enum WelcomeViewInput {
    SetConnections(Vec<SavedConnection>),
    SetOrganization(ConnectionOrganizationIndex),
    FilterChanged(String),
    OpenConnect,
    ImportUrl,
    OpenSaved(SavedConnection),
    ToggleFavorite(Uuid),
    Organize(SavedConnection),
    Edit(SavedConnection),
    Duplicate(Uuid),
    Delete(Uuid),
    ExportBundle,
    ImportBundle,
}

#[derive(Debug)]
#[allow(clippy::large_enum_variant)]
pub enum WelcomeViewOutput {
    OpenConnect,
    ImportUrl,
    OpenSaved(SavedConnection),
    ToggleFavorite(Uuid),
    Organize(SavedConnection),
    Edit(SavedConnection),
    Duplicate(Uuid),
    Delete(Uuid),
    ExportBundle,
    ImportBundle,
}

#[derive(Debug, Default)]
pub struct WelcomeViewInit;

impl SimpleComponent for WelcomeView {
    type Init = WelcomeViewInit;
    type Input = WelcomeViewInput;
    type Output = WelcomeViewOutput;
    type Root = gtk::Stack;
    type Widgets = ();

    fn init_root() -> Self::Root {
        gtk::Stack::builder().build()
    }

    fn init(_init: Self::Init, root: Self::Root, sender: ComponentSender<Self>) -> ComponentParts<Self> {
        // Empty page — no saved connections yet. GNOME convention is
        // state / instruction / action — title states the situation,
        // description tells the user what to do, the button restates
        // the action with verb-first phrasing (matches Settings's
        // "No printers found" / "Add a printer to begin." / "Add
        // Printer" pattern).
        let empty_page = adw::StatusPage::builder()
            .icon_name("network-server-symbolic")
            .title(crate::tr!("No connections yet"))
            .description(crate::tr!("Add a database connection to get started."))
            .build();
        let empty_btn = gtk::Button::builder()
            .label(crate::tr!("Add Connection"))
            .halign(gtk::Align::Center)
            .build();
        empty_btn.add_css_class("suggested-action");
        empty_btn.add_css_class("pill");
        let s_empty = sender.clone();
        empty_btn.connect_clicked(move |_| s_empty.input(WelcomeViewInput::OpenConnect));
        empty_page.set_child(Some(&empty_btn));
        root.add_named(&empty_page, Some("empty"));

        // Populated page — saved connections list. AdwClamp is the
        // GNOME pattern for "constrain reading width to a sensible
        // max in a scrollable area"; it centres + caps width without
        // the manual `gtk::Box` halign/margin gymnastics.
        let scroller = gtk::ScrolledWindow::builder()
            .hexpand(true)
            .vexpand(true)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .build();
        let clamp = adw::Clamp::builder().maximum_size(560).build();
        let outer = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .margin_top(24)
            .margin_bottom(24)
            .margin_start(12)
            .margin_end(12)
            .build();

        // Single CTA on the populated page: the "+" button in the
        // group header. Previously we also rendered a bottom pill
        // labelled "New connection", which duplicated the affordance —
        // ambiguity at different visual weights. Empty-page pill
        // stays (it's the only CTA there); on this page the header
        // suffix is sufficient.
        let group = adw::PreferencesGroup::builder()
            .title(crate::tr!("Saved connections"))
            .build();
        let header_btn = gtk::Button::builder()
            .icon_name("list-add-symbolic")
            .tooltip_text(crate::tr!("Add Connection"))
            .valign(gtk::Align::Center)
            .build();
        header_btn.add_css_class("flat");
        let s_header = sender.clone();
        header_btn.connect_clicked(move |_| s_header.input(WelcomeViewInput::OpenConnect));
        // Import sits beside Add rather than inside a menu: pasting a
        // connection URL is the fastest path in from another tool, and
        // GNOME puts sibling create-actions side by side in the group
        // header (Software's "Add" / "Install File…" pattern).
        let import_btn = gtk::Button::builder()
            .icon_name("insert-link-symbolic")
            .tooltip_text(crate::tr!("Import from URL"))
            .valign(gtk::Align::Center)
            .build();
        import_btn.add_css_class("flat");
        let s_import = sender.clone();
        import_btn.connect_clicked(move |_| s_import.input(WelcomeViewInput::ImportUrl));
        let header_actions = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(6)
            .build();
        let bundle_btn = gtk::MenuButton::builder()
            .icon_name("document-send-symbolic")
            .tooltip_text(crate::tr!("Export or import connections"))
            .valign(gtk::Align::Center)
            .build();
        bundle_btn.add_css_class("flat");
        let bundle_menu = gtk::gio::Menu::new();
        bundle_menu.append(Some(&crate::tr!("Export connections…")), Some("welcome.export-bundle"));
        bundle_menu.append(Some(&crate::tr!("Import connections…")), Some("welcome.import-bundle"));
        bundle_btn.set_menu_model(Some(&bundle_menu));

        let actions = gtk::gio::SimpleActionGroup::new();
        let export_action = gtk::gio::SimpleAction::new("export-bundle", None);
        let s_export = sender.clone();
        export_action.connect_activate(move |_, _| s_export.input(WelcomeViewInput::ExportBundle));
        actions.add_action(&export_action);
        let import_action = gtk::gio::SimpleAction::new("import-bundle", None);
        let s_bundle_import = sender.clone();
        import_action.connect_activate(move |_, _| s_bundle_import.input(WelcomeViewInput::ImportBundle));
        actions.add_action(&import_action);
        root.insert_action_group("welcome", Some(&actions));

        header_actions.append(&import_btn);
        header_actions.append(&bundle_btn);
        header_actions.append(&header_btn);
        group.set_header_suffix(Some(&header_actions));

        // Filter box above the list. Hidden until there are enough
        // connections to be worth filtering — a search field over three
        // rows is noise, and GNOME only reveals search once a list can
        // outgrow the viewport.
        let search = gtk::SearchEntry::builder()
            .placeholder_text(crate::tr!("Filter by name, group, tag or driver"))
            .hexpand(true)
            .visible(false)
            .build();
        let s_search = sender.clone();
        search.connect_search_changed(move |entry| {
            s_search.input(WelcomeViewInput::FilterChanged(entry.text().to_string()));
        });
        outer.append(&search);
        outer.append(&group);
        let sections_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .build();
        outer.append(&sections_box);

        // Shown in place of the list when every connection is filtered
        // out. Distinct from the "no connections yet" page: the fix is
        // to clear the filter, not to add a connection.
        let empty_filter_page = adw::StatusPage::builder()
            .icon_name("system-search-symbolic")
            .title(crate::tr!("No matches"))
            .description(crate::tr!("No saved connection matches this filter."))
            .visible(false)
            .build();
        empty_filter_page.add_css_class("compact");
        outer.append(&empty_filter_page);
        clamp.set_child(Some(&outer));

        scroller.set_child(Some(&clamp));
        root.add_named(&scroller, Some("populated"));
        root.set_visible_child_name("empty");

        let model = WelcomeView {
            connections: Vec::new(),
            organization: ConnectionOrganizationIndex::default(),
            filter: String::new(),
            sections: Vec::new(),
            sections_box,
            stack: root.clone(),
            search,
            empty_filter_page,
        };
        ComponentParts { model, widgets: () }
    }

    fn update(&mut self, msg: Self::Input, sender: ComponentSender<Self>) {
        match msg {
            WelcomeViewInput::SetConnections(connections) => {
                self.connections = connections;
                self.rebuild_rows(&sender);
            }
            WelcomeViewInput::SetOrganization(organization) => {
                self.organization = organization;
                self.rebuild_rows(&sender);
            }
            WelcomeViewInput::FilterChanged(filter) => {
                self.filter = filter;
                self.rebuild_rows(&sender);
            }
            WelcomeViewInput::OpenConnect => {
                let _ = sender.output(WelcomeViewOutput::OpenConnect);
            }
            WelcomeViewInput::ImportUrl => {
                let _ = sender.output(WelcomeViewOutput::ImportUrl);
            }
            WelcomeViewInput::OpenSaved(saved) => {
                let _ = sender.output(WelcomeViewOutput::OpenSaved(saved));
            }
            WelcomeViewInput::ToggleFavorite(id) => {
                let _ = sender.output(WelcomeViewOutput::ToggleFavorite(id));
            }
            WelcomeViewInput::Organize(saved) => {
                let _ = sender.output(WelcomeViewOutput::Organize(saved));
            }
            WelcomeViewInput::Edit(saved) => {
                let _ = sender.output(WelcomeViewOutput::Edit(saved));
            }
            WelcomeViewInput::Duplicate(id) => {
                let _ = sender.output(WelcomeViewOutput::Duplicate(id));
            }
            WelcomeViewInput::ExportBundle => {
                let _ = sender.output(WelcomeViewOutput::ExportBundle);
            }
            WelcomeViewInput::ImportBundle => {
                let _ = sender.output(WelcomeViewOutput::ImportBundle);
            }
            WelcomeViewInput::Delete(id) => {
                let _ = sender.output(WelcomeViewOutput::Delete(id));
            }
        }
    }
}

/// Connections a filter cannot outgrow. Below this the filter box stays
/// hidden, so the field only appears once scanning the list by eye stops
/// being the faster option.
const FILTER_REVEAL_THRESHOLD: usize = 6;

impl WelcomeView {
    fn rebuild_rows(&mut self, sender: &ComponentSender<Self>) {
        // Favourites first, then group, then name — the ordering lives
        // in tablepro-storage so the same arrangement is testable
        // without a GTK main context. Recency is a deliberate casualty:
        // an explicit favourite outranks "whatever I opened last".
        let arranged = arrange_connections(&self.connections, &self.organization, &self.filter);
        let sections = group_sections(&arranged, &self.organization);

        self.sections.clear();
        while let Some(child) = self.sections_box.first_child() {
            self.sections_box.remove(&child);
        }
        for (group, members) in sections {
            self.sections
                .push(self.build_section(group.as_deref(), &members, sender));
        }

        self.search
            .set_visible(self.connections.len() >= FILTER_REVEAL_THRESHOLD);
        self.empty_filter_page
            .set_visible(arranged.is_empty() && !self.connections.is_empty());
        let name = if self.connections.is_empty() {
            "empty"
        } else {
            "populated"
        };
        self.stack.set_visible_child_name(name);
    }

    fn build_section(
        &self,
        group: Option<&str>,
        members: &[SavedConnection],
        sender: &ComponentSender<Self>,
    ) -> FactoryVecDeque<ConnectionRow> {
        let mut factory: FactoryVecDeque<ConnectionRow> = FactoryVecDeque::builder()
            .launch(
                gtk::ListBox::builder()
                    .selection_mode(gtk::SelectionMode::None)
                    .css_classes(["boxed-list"])
                    .build(),
            )
            .forward(sender.input_sender(), |out| match out {
                ConnectionRowOutput::Open(saved) => WelcomeViewInput::OpenSaved(saved),
                ConnectionRowOutput::ToggleFavorite(id) => WelcomeViewInput::ToggleFavorite(id),
                ConnectionRowOutput::Organize(saved) => WelcomeViewInput::Organize(saved),
                ConnectionRowOutput::Edit(saved) => WelcomeViewInput::Edit(saved),
                ConnectionRowOutput::Duplicate(id) => WelcomeViewInput::Duplicate(id),
                ConnectionRowOutput::Delete(id) => WelcomeViewInput::Delete(id),
            });
        let mut guard = factory.guard();
        for saved in members {
            let organization = self.organization.get(saved.id);
            guard.push_back(ConnectionRowInit {
                saved: saved.clone(),
                organization,
            });
        }
        drop(guard);

        let section = adw::PreferencesGroup::builder()
            .title(group.map_or_else(|| crate::tr!("Ungrouped"), str::to_owned))
            .build();
        section.add(factory.widget());
        self.sections_box.append(&section);
        factory
    }
}

/// Bucket an already-arranged list into the groups the list renders.
/// Bucket order and the order inside each bucket both follow
/// `arrange_connections`, so grouping never reorders what the user
/// already sees; it only draws a heading between runs.
fn group_sections(
    arranged: &[SavedConnection],
    index: &ConnectionOrganizationIndex,
) -> Vec<(Option<String>, Vec<SavedConnection>)> {
    let mut sections: Vec<(Option<String>, Vec<SavedConnection>)> = Vec::new();
    for saved in arranged {
        let group = index.get(saved.id).group;
        match sections.iter_mut().find(|(name, _)| *name == group) {
            Some((_, members)) => members.push(saved.clone()),
            None => sections.push((group, vec![saved.clone()])),
        }
    }
    sections
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::{AuthMode, Environment, TlsMode};
    use tablepro_storage::ConnectionOrganization;

    fn saved(name: &str) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: name.into(),
            driver_id: "postgres".into(),
            host: "localhost".into(),
            port: 5432,
            socket_dir: None,
            database: "app".into(),
            username: "app".into(),
            use_tls: false,
            tls_mode: Some(TlsMode::Disabled),
            tls_root_cert: None,
            tls_client_cert: None,
            tls_client_key: None,
            read_only: false,
            auth_mode: AuthMode::Password,
            environment: Environment::Local,
            ssh: None,
            last_opened_at: None,
            connect_timeout_secs: None,
            query_timeout_secs: None,
        }
    }

    fn index(entries: &[(Uuid, Option<&str>, bool)]) -> ConnectionOrganizationIndex {
        let mut index = ConnectionOrganizationIndex::default();
        for (id, group, favorite) in entries {
            let organization = ConnectionOrganization::new(*group, &[], *favorite).expect("valid organization");
            index.set(*id, organization).expect("set");
        }
        index
    }

    #[test]
    fn connections_without_a_group_render_as_one_ungrouped_section() {
        let first = saved("alpha");
        let second = saved("beta");
        let arranged = vec![first.clone(), second.clone()];

        let sections = group_sections(&arranged, &ConnectionOrganizationIndex::default());

        assert_eq!(sections.len(), 1);
        assert_eq!(sections[0].0, None);
        assert_eq!(sections[0].1.len(), 2);
    }

    #[test]
    fn each_group_becomes_its_own_section_in_arranged_order() {
        let prod = saved("prod db");
        let staging = saved("staging db");
        let loose = saved("scratch");
        let index = index(&[
            (prod.id, Some("Production"), false),
            (staging.id, Some("Staging"), false),
        ]);
        let arranged = vec![prod.clone(), staging.clone(), loose.clone()];

        let sections = group_sections(&arranged, &index);

        assert_eq!(
            sections.iter().map(|(name, _)| name.clone()).collect::<Vec<_>>(),
            vec![Some("Production".to_owned()), Some("Staging".to_owned()), None,]
        );
        assert_eq!(sections[2].1[0].id, loose.id);
    }

    #[test]
    fn a_group_that_reappears_later_keeps_one_section() {
        let first = saved("a");
        let other = saved("b");
        let third = saved("c");
        let index = index(&[
            (first.id, Some("Production"), false),
            (other.id, Some("Staging"), false),
            (third.id, Some("Production"), false),
        ]);
        let arranged = vec![first.clone(), other, third.clone()];

        let sections = group_sections(&arranged, &index);

        assert_eq!(sections.len(), 2);
        assert_eq!(sections[0].0.as_deref(), Some("Production"));
        assert_eq!(sections[0].1.len(), 2);
        assert_eq!(sections[0].1[0].id, first.id);
        assert_eq!(sections[0].1[1].id, third.id);
    }

    #[test]
    fn an_empty_arrangement_renders_no_sections() {
        assert!(group_sections(&[], &ConnectionOrganizationIndex::default()).is_empty());
    }
}
