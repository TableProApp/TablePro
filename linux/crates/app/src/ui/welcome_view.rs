use relm4::adw::prelude::*;
use relm4::factory::FactoryVecDeque;
use relm4::prelude::*;
use relm4::{adw, gtk};

use tablepro_storage::SavedConnection;
use uuid::Uuid;

use super::connection_row::{ConnectionRow, ConnectionRowOutput};

pub struct WelcomeView {
    connections: Vec<SavedConnection>,
    factory: FactoryVecDeque<ConnectionRow>,
    stack: gtk::Stack,
}

#[derive(Debug)]
#[allow(clippy::large_enum_variant)]
pub enum WelcomeViewInput {
    SetConnections(Vec<SavedConnection>),
    OpenConnect,
    OpenSaved(SavedConnection),
    Delete(Uuid),
}

#[derive(Debug)]
#[allow(clippy::large_enum_variant)]
pub enum WelcomeViewOutput {
    OpenConnect,
    OpenSaved(SavedConnection),
    Delete(Uuid),
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
        let factory: FactoryVecDeque<ConnectionRow> = FactoryVecDeque::builder()
            .launch(
                gtk::ListBox::builder()
                    .selection_mode(gtk::SelectionMode::None)
                    .css_classes(["boxed-list"])
                    .build(),
            )
            .forward(sender.input_sender(), |out| match out {
                ConnectionRowOutput::Open(saved) => WelcomeViewInput::OpenSaved(saved),
                ConnectionRowOutput::Delete(id) => WelcomeViewInput::Delete(id),
            });

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
        group.set_header_suffix(Some(&header_btn));
        group.add(factory.widget());
        outer.append(&group);
        clamp.set_child(Some(&outer));

        scroller.set_child(Some(&clamp));
        root.add_named(&scroller, Some("populated"));
        root.set_visible_child_name("empty");

        let model = WelcomeView {
            connections: Vec::new(),
            factory,
            stack: root.clone(),
        };
        ComponentParts { model, widgets: () }
    }

    fn update(&mut self, msg: Self::Input, sender: ComponentSender<Self>) {
        match msg {
            WelcomeViewInput::SetConnections(connections) => {
                // Recency-first with alphabetical tiebreaker. Connections
                // that have been opened sort newest-first; never-opened
                // entries (no timestamp) fall to the bottom and sort
                // alphabetically among themselves. Mirrors GNOME Files'
                // recent-files panel and DataGrip / TablePlus welcome
                // screens — the connection the user opened last is
                // almost always the one they want next.
                self.connections = connections;
                self.connections.sort_by(|a, b| {
                    use std::cmp::Ordering;
                    match (a.last_opened_at, b.last_opened_at) {
                        (Some(ta), Some(tb)) => tb
                            .cmp(&ta)
                            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())),
                        (Some(_), None) => Ordering::Less,
                        (None, Some(_)) => Ordering::Greater,
                        (None, None) => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
                    }
                });
                let mut guard = self.factory.guard();
                guard.clear();
                for saved in &self.connections {
                    guard.push_back(saved.clone());
                }
                drop(guard);
                let name = if self.connections.is_empty() {
                    "empty"
                } else {
                    "populated"
                };
                self.stack.set_visible_child_name(name);
            }
            WelcomeViewInput::OpenConnect => {
                let _ = sender.output(WelcomeViewOutput::OpenConnect);
            }
            WelcomeViewInput::OpenSaved(saved) => {
                let _ = sender.output(WelcomeViewOutput::OpenSaved(saved));
            }
            WelcomeViewInput::Delete(id) => {
                let _ = sender.output(WelcomeViewOutput::Delete(id));
            }
        }
    }
}
