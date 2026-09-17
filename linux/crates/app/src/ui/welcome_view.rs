use relm4::adw::prelude::*;
use relm4::factory::FactoryVecDeque;
use relm4::prelude::*;
use relm4::{adw, gtk};

use tablepro_storage::{ConnectionColor, SavedConnection};
use uuid::Uuid;

use super::connection_list;
use super::connection_row::{ConnectionRow, ConnectionRowInit, ConnectionRowOutput};

pub struct WelcomeView {
    connections: Vec<SavedConnection>,
    factory: FactoryVecDeque<ConnectionRow>,
    /// The factory's own list box, kept so the group headers can be
    /// reinstalled whenever the list changes.
    listbox: gtk::ListBox,
    stack: gtk::Stack,
}

#[derive(Debug)]
pub enum WelcomeViewInput {
    SetConnections(Vec<SavedConnection>),
    OpenConnect,
    OpenSaved(SavedConnection),
    Delete(Uuid),
    Duplicate(SavedConnection),
    SetColor(Uuid, Option<ConnectionColor>),
    SetGroup(Uuid, Option<String>),
}

#[derive(Debug)]
pub enum WelcomeViewOutput {
    OpenConnect,
    OpenSaved(SavedConnection),
    Delete(Uuid),
    Duplicate(SavedConnection),
    SetColor(Uuid, Option<ConnectionColor>),
    SetGroup(Uuid, Option<String>),
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
        let listbox = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .css_classes(["boxed-list"])
            .build();
        let factory: FactoryVecDeque<ConnectionRow> =
            FactoryVecDeque::builder()
                .launch(listbox.clone())
                .forward(sender.input_sender(), |out| match out {
                    ConnectionRowOutput::Open(saved) => WelcomeViewInput::OpenSaved(saved),
                    ConnectionRowOutput::Delete(id) => WelcomeViewInput::Delete(id),
                    ConnectionRowOutput::Duplicate(saved) => WelcomeViewInput::Duplicate(saved),
                    ConnectionRowOutput::SetColor(id, color) => WelcomeViewInput::SetColor(id, color),
                    ConnectionRowOutput::SetGroup(id, group) => WelcomeViewInput::SetGroup(id, group),
                });

        // Empty page — no saved connections yet. GNOME convention is
        // state / instruction / action — title states the situation,
        // description tells the user what to do, the button restates
        // the action with verb-first phrasing (matches Settings's
        // "No printers found" / "Add a printer to begin." / "Add
        // Printer" pattern).
        let empty_page = adw::StatusPage::builder()
            .icon_name(crate::ui::icons::NETWORK_SERVER)
            .title(crate::i18n::gettext("No connections yet"))
            .description(crate::i18n::gettext("Add a database connection to get started."))
            .build();
        let empty_btn = gtk::Button::builder()
            .label(crate::i18n::gettext("Add Connection"))
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
            .title(crate::i18n::gettext("Saved connections"))
            .build();
        let header_btn = gtk::Button::builder()
            .icon_name(crate::ui::icons::LIST_ADD)
            .tooltip_text(crate::i18n::gettext("Add Connection"))
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
            listbox,
            stack: root.clone(),
        };
        ComponentParts { model, widgets: () }
    }

    fn update(&mut self, msg: Self::Input, sender: ComponentSender<Self>) {
        match msg {
            WelcomeViewInput::SetConnections(connections) => {
                self.connections = connections;
                connection_list::sort(&mut self.connections);
                let groups = connection_list::groups(&self.connections);
                let mut guard = self.factory.guard();
                guard.clear();
                for saved in &self.connections {
                    guard.push_back(ConnectionRowInit {
                        saved: saved.clone(),
                        groups: groups.clone(),
                    });
                }
                drop(guard);
                connection_list::install_group_headers(&self.listbox, std::rc::Rc::new(self.connections.clone()));
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
            WelcomeViewInput::Duplicate(saved) => {
                let _ = sender.output(WelcomeViewOutput::Duplicate(saved));
            }
            WelcomeViewInput::SetColor(id, color) => {
                let _ = sender.output(WelcomeViewOutput::SetColor(id, color));
            }
            WelcomeViewInput::SetGroup(id, group) => {
                let _ = sender.output(WelcomeViewOutput::SetGroup(id, group));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn connection(name: &str, group: Option<&str>) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: name.to_owned(),
            driver_id: "postgres".to_owned(),
            host: "db".to_owned(),
            port: 5432,
            database: "app".to_owned(),
            username: "postgres".to_owned(),
            use_tls: true,
            read_only: false,
            auth_mode: tablepro_core::AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: group.map(str::to_owned),
        }
    }

    /// The header text on each row, in list order, with `None` where a
    /// row carries no header.
    fn headers(view: &WelcomeView) -> Vec<Option<String>> {
        (0..)
            .map_while(|index| view.listbox.row_at_index(index))
            .map(|row| {
                row.header()
                    .and_then(|widget| widget.downcast::<gtk::Label>().ok())
                    .map(|label| label.label().to_string())
            })
            .collect()
    }

    #[gtk4::test]
    fn a_grouped_list_carries_one_header_per_group() {
        let view = WelcomeView::builder().launch(WelcomeViewInit);
        view.sender()
            .send(WelcomeViewInput::SetConnections(vec![
                connection("loose", None),
                connection("a", Some("Work")),
                connection("b", Some("Work")),
                connection("c", Some("Zoo")),
            ]))
            .expect("send");

        crate::test_support::drain_main_context();

        assert_eq!(
            headers(&view.model()),
            vec![None, Some("Work".to_owned()), None, Some("Zoo".to_owned())]
        );
    }

    #[gtk4::test]
    fn an_ungrouped_list_carries_no_headers_at_all() {
        let view = WelcomeView::builder().launch(WelcomeViewInit);
        view.sender()
            .send(WelcomeViewInput::SetConnections(vec![
                connection("a", None),
                connection("b", None),
            ]))
            .expect("send");

        crate::test_support::drain_main_context();

        assert_eq!(headers(&view.model()), vec![None, None]);
    }

    #[gtk4::test]
    fn taking_the_last_connection_out_of_a_group_takes_its_header_with_it() {
        let view = WelcomeView::builder().launch(WelcomeViewInit);
        view.sender()
            .send(WelcomeViewInput::SetConnections(vec![connection("a", Some("Work"))]))
            .expect("send");
        crate::test_support::drain_main_context();
        assert_eq!(headers(&view.model()), vec![Some("Work".to_owned())]);

        view.sender()
            .send(WelcomeViewInput::SetConnections(vec![connection("a", None)]))
            .expect("send");
        crate::test_support::drain_main_context();

        assert_eq!(headers(&view.model()), vec![None]);
    }
}
