use std::cell::RefCell;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_storage::{ConnectionProject, ConnectionProjectName};
use uuid::Uuid;

use super::project_name_dialog::{ask_new_project, ask_project_rename};
use crate::runtime::{DeliverInput, InputSender};
use crate::services::saved_connection_list::SavedConnectionList;
use crate::ui::a11y::describe_icon_button;
use crate::ui::{LibraryEdit, SessionWindowInput};

const CANCEL: &str = "cancel";
const DELETE: &str = "delete";

// Every project, to rename, reorder or delete, following the list as any window changes it.
pub(crate) struct ManageProjectsDialog {
    pub(crate) dialog: adw::Dialog,
    group: adw::PreferencesGroup,
    stack: gtk::Stack,
    list: Rc<SavedConnectionList>,
    sender: InputSender<SessionWindowInput>,
    rows: RefCell<Vec<adw::ActionRow>>,
    // What the rows show, so a write that changed no project keeps them and the focus on them.
    shown: RefCell<Option<Vec<(ConnectionProject, usize)>>>,
}

impl ManageProjectsDialog {
    pub(crate) fn new(list: Rc<SavedConnectionList>, sender: InputSender<SessionWindowInput>) -> Rc<Self> {
        let group = adw::PreferencesGroup::new();
        let add = gtk::Button::from_icon_name(crate::ui::icons::LIST_ADD);
        describe_icon_button(&add, &crate::i18n::gettext("New Project"), None);
        let page = adw::PreferencesPage::new();
        page.add(&group);
        let empty = adw::StatusPage::builder()
            .title(crate::i18n::gettext("No Projects"))
            .description(crate::i18n::gettext(
                "A project shows only its own connections, with their history and saved queries. All Connections \
                 shows every one.",
            ))
            .build();
        let new_project = gtk::Button::builder()
            .label(crate::i18n::gettext("New Project"))
            .halign(gtk::Align::Center)
            .build();
        new_project.set_css_classes(&["pill", "suggested-action"]);
        empty.set_child(Some(&new_project));
        let stack = gtk::Stack::new();
        stack.add_named(&page, Some("projects"));
        stack.add_named(&empty, Some("empty"));
        let header = adw::HeaderBar::new();
        header.pack_start(&add);
        let view = adw::ToolbarView::new();
        view.add_top_bar(&header);
        view.set_content(Some(&stack));
        let dialog = adw::Dialog::builder()
            .title(crate::i18n::gettext("Manage Projects"))
            .content_width(420)
            .content_height(480)
            .child(&view)
            .build();
        let this = Rc::new(Self {
            dialog,
            group,
            stack,
            list,
            sender,
            rows: RefCell::new(Vec::new()),
            shown: RefCell::new(None),
        });
        for button in [&add, &new_project] {
            let weak = Rc::downgrade(&this);
            button.connect_clicked(move |_| {
                if let Some(this) = weak.upgrade() {
                    this.create();
                }
            });
        }
        let weak = Rc::downgrade(&this);
        let observer = this.list.connect_state_changed(move |_| {
            if let Some(this) = weak.upgrade() {
                this.refresh();
            }
        });
        let list = this.list.clone();
        this.dialog
            .connect_closed(move |_| list.disconnect_state_changed(observer));
        this.refresh();
        this
    }

    // Each project in order, with how many connections it holds.
    fn wanted(&self) -> Vec<(ConnectionProject, usize)> {
        let Some(library) = self.list.library() else {
            return Vec::new();
        };
        let membership = library.membership();
        library
            .projects_in_order()
            .into_iter()
            .map(|project| {
                let held = library
                    .connections
                    .iter()
                    .filter(|saved| membership.of_connection(saved) == Some(project.id))
                    .count();
                (project.clone(), held)
            })
            .collect()
    }

    fn refresh(self: &Rc<Self>) {
        let wanted = self.wanted();
        if self.shown.borrow().as_ref() == Some(&wanted) {
            return;
        }
        for row in self.rows.take() {
            self.group.remove(&row);
        }
        let last = wanted.len().saturating_sub(1);
        let rows: Vec<adw::ActionRow> = wanted
            .iter()
            .enumerate()
            .map(|(at, (project, count))| self.row(project, *count, at > 0, at < last))
            .collect();
        for row in &rows {
            self.group.add(row);
        }
        self.stack
            .set_visible_child_name(if rows.is_empty() { "empty" } else { "projects" });
        self.rows.replace(rows);
        self.shown.replace(Some(wanted));
    }

    fn row(self: &Rc<Self>, project: &ConnectionProject, count: usize, up: bool, down: bool) -> adw::ActionRow {
        let row = adw::ActionRow::builder()
            .title(project.name.as_str())
            .use_markup(false)
            .subtitle(holding(count))
            .activatable(true)
            .build();
        let id = project.id;
        for (icon, label, enabled, step) in [
            (crate::ui::icons::GO_UP, crate::i18n::gettext("Move Up"), up, Step::Up),
            (
                crate::ui::icons::GO_DOWN,
                crate::i18n::gettext("Move Down"),
                down,
                Step::Down,
            ),
        ] {
            let button = flat_button(icon, &label);
            button.set_sensitive(enabled);
            let weak = Rc::downgrade(self);
            button.connect_clicked(move |_| {
                if let Some(this) = weak.upgrade() {
                    this.step(id, step);
                }
            });
            row.add_suffix(&button);
        }
        let delete = flat_button(crate::ui::icons::USER_TRASH, &crate::i18n::gettext("Delete Project"));
        row.add_suffix(&delete);
        let weak = Rc::downgrade(self);
        row.connect_activated(move |_| {
            if let Some(this) = weak.upgrade() {
                this.rename(id);
            }
        });
        let weak = Rc::downgrade(self);
        delete.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.delete(id);
            }
        });
        row
    }

    fn names(&self, except: Option<Uuid>) -> Vec<ConnectionProjectName> {
        self.list
            .projects()
            .into_iter()
            .filter(|project| Some(project.id) != except)
            .map(|project| project.name)
            .collect()
    }

    fn deliver(&self, edit: LibraryEdit) {
        self.sender.deliver(SessionWindowInput::Library(edit));
    }

    fn create(self: &Rc<Self>) {
        let (dialog, taken, sender) = (self.dialog.clone(), self.names(None), self.sender.clone());
        glib::spawn_future_local(async move {
            if let Some(name) = ask_new_project(dialog.upcast_ref(), taken).await {
                sender.deliver(SessionWindowInput::Library(LibraryEdit::CreateProject {
                    name,
                    switch: false,
                }));
            }
        });
    }

    fn rename(self: &Rc<Self>, id: Uuid) {
        let Some(project) = self.list.projects().into_iter().find(|project| project.id == id) else {
            return;
        };
        let (dialog, taken, sender) = (self.dialog.clone(), self.names(Some(id)), self.sender.clone());
        glib::spawn_future_local(async move {
            if let Some(name) = ask_project_rename(dialog.upcast_ref(), taken, &project.name).await {
                sender.deliver(SessionWindowInput::Library(LibraryEdit::RenameProject(id, name)));
            }
        });
    }

    fn step(&self, id: Uuid, step: Step) {
        let ids: Vec<Uuid> = self.list.projects().iter().map(|project| project.id).collect();
        if let Some(before) = stepped(&ids, id, step) {
            self.deliver(LibraryEdit::MoveProject { id, before });
        }
    }

    // A delete keeps the connections, so it asks first and says so.
    fn delete(self: &Rc<Self>, id: Uuid) {
        let Some(project) = self.list.projects().into_iter().find(|project| project.id == id) else {
            return;
        };
        let asking = delete_alert(&project);
        let (dialog, sender) = (self.dialog.clone(), self.sender.clone());
        glib::spawn_future_local(async move {
            if crate::workspace::respond(&asking, dialog.upcast_ref()).await == DELETE {
                sender.deliver(SessionWindowInput::Library(LibraryEdit::DeleteProject(id)));
            }
        });
    }

    #[cfg(test)]
    pub(crate) fn rows(&self) -> Vec<(String, String)> {
        self.rows
            .borrow()
            .iter()
            .map(|row| (row.title().to_string(), row.subtitle().unwrap_or_default().to_string()))
            .collect()
    }

    #[cfg(test)]
    pub(crate) fn page(&self) -> Option<String> {
        self.stack.visible_child_name().map(|name| name.to_string())
    }

    #[cfg(test)]
    fn button(&self, row: usize, label: &str) -> gtk::Button {
        let row = self.rows.borrow()[row].clone();
        crate::test_support::descendants(&row)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
            .find(|button| button.tooltip_text().as_deref() == Some(label))
            .expect("the row's button")
    }
}

#[derive(Debug, Clone, Copy)]
enum Step {
    Up,
    Down,
}

// `Some(None)` is a step down to the last place.
fn stepped(ids: &[Uuid], id: Uuid, step: Step) -> Option<Option<Uuid>> {
    let at = ids.iter().position(|held| *held == id)?;
    match step {
        Step::Up => at
            .checked_sub(1)
            .and_then(|above| ids.get(above))
            .map(|above| Some(*above)),
        Step::Down if at + 1 < ids.len() => Some(ids.get(at + 2).copied()),
        Step::Down => None,
    }
}

fn flat_button(icon: &str, label: &str) -> gtk::Button {
    let button = gtk::Button::builder()
        .icon_name(icon)
        .valign(gtk::Align::Center)
        .build();
    button.add_css_class("flat");
    describe_icon_button(&button, label, None);
    button
}

fn holding(count: usize) -> String {
    if count == 0 {
        return crate::i18n::gettext("No connections");
    }
    crate::i18n::ngettext_f("{n} connection", "{n} connections", count, &[("n", &count.to_string())])
}

pub(super) fn delete_alert(project: &ConnectionProject) -> adw::AlertDialog {
    let dialog = adw::AlertDialog::new(
        Some(&crate::i18n::gettext_f(
            "Delete “{project}”?",
            &[("project", project.name.as_str())],
        )),
        Some(&crate::i18n::gettext(
            "Its connections and groups are kept. They stay in All Connections.",
        )),
    );
    dialog.add_response(CANCEL, &crate::i18n::gettext("Cancel"));
    dialog.add_response(DELETE, &crate::i18n::gettext("Delete"));
    dialog.set_response_appearance(DELETE, adw::ResponseAppearance::Destructive);
    dialog.set_default_response(Some(CANCEL));
    dialog.set_close_response(CANCEL);
    dialog
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use tablepro_storage::{
        ConnectionGroup, ConnectionGroupName, ConnectionList, ConnectionListState, SavedConnection,
    };

    use super::*;
    use crate::test_support::{saved_connection, wait_until};

    const WAIT: std::time::Duration = std::time::Duration::from_secs(10);

    fn project(name: &str, order: u32) -> ConnectionProject {
        ConnectionProject {
            order,
            ..ConnectionProject::new(ConnectionProjectName::new(name).expect("a project name"))
        }
    }

    fn list() -> (Rc<SavedConnectionList>, tempfile::TempDir) {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = tablepro_storage::ConnectionStore::new(&tablepro_storage::StoragePaths::under(
            dir.path(),
            "tablepro",
            crate::config::APP_ID,
        ));
        (
            SavedConnectionList::follow(&store, Arc::new(crate::build_registry())),
            dir,
        )
    }

    fn sent(receiver: &mut tokio::sync::mpsc::UnboundedReceiver<SessionWindowInput>) -> Option<LibraryEdit> {
        match receiver.try_recv().ok()? {
            SessionWindowInput::Library(edit) => Some(edit),
            other => panic!("an input that is no library edit: {other:?}"),
        }
    }

    // Acme holds a group with one connection and one ungrouped connection; Side holds nothing.
    fn library() -> (ConnectionList, ConnectionProject, ConnectionProject) {
        let (acme, side) = (project("Acme", 0), project("Side", 1));
        let work = ConnectionGroup {
            project_id: Some(acme.id),
            ..ConnectionGroup::new(ConnectionGroupName::new("Work").expect("a group name"), None)
        };
        let connections = vec![
            SavedConnection {
                group_id: Some(work.id),
                ..saved_connection("grouped")
            },
            SavedConnection {
                project_id: Some(acme.id),
                ..saved_connection("loose")
            },
            saved_connection("in no project"),
        ];
        let list = ConnectionList::new(connections, Vec::new())
            .with_groups(vec![work])
            .with_projects(vec![side.clone(), acme.clone()]);
        (list, acme, side)
    }

    #[gtk4::test]
    fn each_project_shows_in_order_with_its_connections_counted_through_their_groups() {
        let _ = adw::init();
        let (list, _dir) = list();
        let (library, acme, _) = library();
        list.apply(ConnectionListState::Ready(library));
        let (sender, _receiver) = crate::runtime::input_queue::<SessionWindowInput>();

        let manage = ManageProjectsDialog::new(list.clone(), sender);

        assert_eq!(
            manage.rows(),
            [
                ("Acme".to_owned(), "2 connections".to_owned()),
                ("Side".to_owned(), "No connections".to_owned())
            ]
        );
        assert_eq!(manage.page().as_deref(), Some("projects"));
        assert!(
            !manage.button(0, "Move Up").is_sensitive(),
            "the first project moves up"
        );
        assert!(manage.button(0, "Move Down").is_sensitive());
        assert!(manage.button(1, "Move Up").is_sensitive());
        assert!(
            !manage.button(1, "Move Down").is_sensitive(),
            "the last project moves down"
        );
        list.apply(ConnectionListState::Ready(
            ConnectionList::default().with_projects(vec![acme]),
        ));
        assert_eq!(manage.rows(), [("Acme".to_owned(), "No connections".to_owned())]);
        list.apply(ConnectionListState::Ready(ConnectionList::default()));
        assert_eq!(manage.page().as_deref(), Some("empty"));
    }

    #[gtk4::test]
    fn the_arrows_send_the_move_the_store_takes() {
        let _ = adw::init();
        let (list, _dir) = list();
        let (library, acme, side) = library();
        list.apply(ConnectionListState::Ready(library));
        let (sender, mut receiver) = crate::runtime::input_queue::<SessionWindowInput>();
        let manage = ManageProjectsDialog::new(list, sender);

        manage.button(0, "Move Down").emit_clicked();
        assert!(
            matches!(sent(&mut receiver), Some(LibraryEdit::MoveProject { id, before: None }) if id == acme.id),
            "the first of two did not go last"
        );
        manage.button(1, "Move Up").emit_clicked();
        assert!(
            matches!(
                sent(&mut receiver),
                Some(LibraryEdit::MoveProject { id, before: Some(before) }) if id == side.id && before == acme.id
            ),
            "the second did not go before the first"
        );
    }

    #[gtk4::test]
    fn a_closed_dialog_stops_following_the_list() {
        let _ = adw::init();
        let (list, _dir) = list();
        let (sender, _receiver) = crate::runtime::input_queue::<SessionWindowInput>();
        let manage = ManageProjectsDialog::new(list.clone(), sender);
        assert_eq!(
            manage.page().as_deref(),
            Some("empty"),
            "no projects showed a blank page"
        );

        manage.dialog.emit_by_name::<()>("closed", &[]);
        list.apply(ConnectionListState::Ready(
            ConnectionList::default().with_projects(vec![project("Acme", 0)]),
        ));

        assert!(manage.rows().is_empty(), "a closed dialog still followed the list");
    }

    #[gtk4::test]
    fn deleting_asks_with_cancel_the_default_says_the_connections_stay_and_sends_the_delete() {
        let _ = adw::init();
        let (list, _dir) = list();
        let (library, acme, _) = library();
        list.apply(ConnectionListState::Ready(library));
        let (sender, mut receiver) = crate::runtime::input_queue::<SessionWindowInput>();
        let manage = ManageProjectsDialog::new(list, sender);
        let window = crate::test_support::OwnedWindow::presented(adw::Window::new());
        manage.dialog.present(Some(&*window));

        let alert = delete_alert(&acme);
        assert_eq!(alert.heading().as_deref(), Some("Delete “Acme”?"));
        assert_eq!(
            alert.body().as_str(),
            "Its connections and groups are kept. They stay in All Connections."
        );
        assert_eq!(alert.default_response().as_deref(), Some(CANCEL));
        assert_eq!(alert.response_appearance(DELETE), adw::ResponseAppearance::Destructive);

        manage.button(0, "Delete Project").emit_clicked();
        let mut asking = None;
        wait_until(WAIT, || {
            asking = crate::workspace::visible_alert(&*window);
            asking.is_some()
        })
        .expect("the question");
        crate::test_support::respond(&asking.expect("the question"), DELETE);

        let mut edit = None;
        wait_until(WAIT, || {
            edit = sent(&mut receiver);
            edit.is_some()
        })
        .expect("the delete");
        assert!(matches!(edit, Some(LibraryEdit::DeleteProject(id)) if id == acme.id));
    }
}
