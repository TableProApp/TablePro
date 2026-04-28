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

        // Empty page — no saved connections yet.
        let empty_page = adw::StatusPage::builder()
            .icon_name("network-server-symbolic")
            .title(crate::tr!("Connect to a database"))
            .description(crate::tr!("Add a connection to get started."))
            .build();
        let empty_btn = gtk::Button::builder()
            .label(crate::tr!("New connection"))
            .halign(gtk::Align::Center)
            .build();
        empty_btn.add_css_class("suggested-action");
        empty_btn.add_css_class("pill");
        let s_empty = sender.clone();
        empty_btn.connect_clicked(move |_| s_empty.input(WelcomeViewInput::OpenConnect));
        empty_page.set_child(Some(&empty_btn));
        root.add_named(&empty_page, Some("empty"));

        // Populated page — saved connections list.
        let scroller = gtk::ScrolledWindow::builder()
            .hexpand(true)
            .vexpand(true)
            .hscrollbar_policy(gtk::PolicyType::Never)
            // Cap the scrollable content's natural width at 560px so
            // narrow viewports don't push past the window edge.
            .max_content_width(560)
            .propagate_natural_width(true)
            .build();
        let outer = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .margin_top(24)
            .margin_bottom(24)
            .margin_start(24)
            .margin_end(24)
            .halign(gtk::Align::Center)
            .valign(gtk::Align::Center)
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
            .tooltip_text(crate::tr!("New connection"))
            .valign(gtk::Align::Center)
            .build();
        header_btn.add_css_class("flat");
        let s_header = sender.clone();
        header_btn.connect_clicked(move |_| s_header.input(WelcomeViewInput::OpenConnect));
        group.set_header_suffix(Some(&header_btn));
        group.add(factory.widget());
        outer.append(&group);

        scroller.set_child(Some(&outer));
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
                self.connections = connections;
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
