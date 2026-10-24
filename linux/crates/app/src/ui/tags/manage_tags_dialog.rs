use std::cell::RefCell;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_storage::{ConnectionTag, SavedConnection};

use super::tag_dialog::{ask_new_tag, ask_tag_changes};
use crate::runtime::{DeliverInput, InputSender};
use crate::services::saved_connection_list::SavedConnectionList;
use crate::ui::SessionWindowInput;
use crate::ui::a11y::describe_icon_button;
use crate::ui::connection_appearance::color_dot;

const CANCEL: &str = "cancel";
const DELETE: &str = "delete";

/// Every tag, to rename, recolour or delete, following the list as any
/// window changes it.
pub(crate) struct ManageTagsDialog {
    pub(crate) dialog: adw::Dialog,
    group: adw::PreferencesGroup,
    stack: gtk::Stack,
    list: Rc<SavedConnectionList>,
    sender: InputSender<SessionWindowInput>,
    rows: RefCell<Vec<adw::ActionRow>>,
    /// What the rows show, so a write that changed no tag keeps them.
    /// `None` until the first fill.
    shown: RefCell<Option<Vec<(ConnectionTag, usize)>>>,
}

impl ManageTagsDialog {
    pub(crate) fn new(list: Rc<SavedConnectionList>, sender: InputSender<SessionWindowInput>) -> Rc<Self> {
        let group = adw::PreferencesGroup::new();
        // As the connection list's own add button, at the header's start.
        let add = gtk::Button::from_icon_name(crate::ui::icons::LIST_ADD);
        describe_icon_button(&add, &crate::i18n::gettext("New Tag"), None);
        let page = adw::PreferencesPage::new();
        page.add(&group);
        let empty = adw::StatusPage::builder()
            .title(crate::i18n::gettext("No Tags"))
            .description(crate::i18n::gettext(
                "Tags label connections across groups. Add one here or from a connection’s menu.",
            ))
            .build();
        let new_tag = gtk::Button::builder()
            .label(crate::i18n::gettext("New Tag"))
            .halign(gtk::Align::Center)
            .build();
        new_tag.set_css_classes(&["pill", "suggested-action"]);
        empty.set_child(Some(&new_tag));
        let stack = gtk::Stack::new();
        stack.add_named(&page, Some("tags"));
        stack.add_named(&empty, Some("empty"));
        let header = adw::HeaderBar::new();
        header.pack_start(&add);
        let view = adw::ToolbarView::new();
        view.add_top_bar(&header);
        view.set_content(Some(&stack));
        let dialog = adw::Dialog::builder()
            .title(crate::i18n::gettext("Manage Tags"))
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
        for button in [&add, &new_tag] {
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

    /// Each tag with how many connections carry it, by name.
    fn wanted(&self) -> Vec<(ConnectionTag, usize)> {
        let connections = self.list.connections();
        self.list
            .tags()
            .iter()
            .map(|tag| (tag.clone(), carriers(&connections, tag)))
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
        let rows: Vec<adw::ActionRow> = wanted.iter().map(|(tag, count)| self.row(tag, *count)).collect();
        for row in &rows {
            self.group.add(row);
        }
        self.stack
            .set_visible_child_name(if rows.is_empty() { "empty" } else { "tags" });
        self.rows.replace(rows);
        self.shown.replace(Some(wanted));
    }

    fn row(self: &Rc<Self>, tag: &ConnectionTag, count: usize) -> adw::ActionRow {
        let row = adw::ActionRow::builder()
            .title(tag.name.as_str())
            .use_markup(false)
            .subtitle(used_by(count))
            .activatable(true)
            .build();
        row.add_prefix(&color_dot(Some(tag.color)));
        let delete = gtk::Button::builder()
            .icon_name(crate::ui::icons::USER_TRASH)
            .valign(gtk::Align::Center)
            .build();
        delete.add_css_class("flat");
        describe_icon_button(&delete, &crate::i18n::gettext("Delete Tag"), None);
        row.add_suffix(&delete);
        let (weak, id) = (Rc::downgrade(self), tag.id);
        row.connect_activated(move |_| {
            if let Some(this) = weak.upgrade() {
                this.edit(id);
            }
        });
        let (weak, id) = (Rc::downgrade(self), tag.id);
        delete.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.delete(id);
            }
        });
        row
    }

    fn create(self: &Rc<Self>) {
        let (dialog, tags, sender) = (self.dialog.clone(), self.list.tags(), self.sender.clone());
        glib::spawn_future_local(async move {
            if let Some((name, color)) = ask_new_tag(dialog.upcast_ref(), &tags).await {
                sender.deliver(SessionWindowInput::CreateTag { name, color, on: None });
            }
        });
    }

    fn edit(self: &Rc<Self>, id: uuid::Uuid) {
        let tags = self.list.tags();
        let Some(tag) = tags.iter().find(|tag| tag.id == id).cloned() else {
            return;
        };
        let (dialog, sender) = (self.dialog.clone(), self.sender.clone());
        glib::spawn_future_local(async move {
            if let Some((name, color)) = ask_tag_changes(dialog.upcast_ref(), &tags, &tag).await {
                sender.deliver(SessionWindowInput::UpdateTag(ConnectionTag { name, color, ..tag }));
            }
        });
    }

    /// A delete takes the tag off every connection, so it asks first and
    /// says how many that is.
    fn delete(self: &Rc<Self>, id: uuid::Uuid) {
        let Some(tag) = self.list.tags().iter().find(|tag| tag.id == id).cloned() else {
            return;
        };
        let asking = delete_alert(&tag, carriers(&self.list.connections(), &tag));
        let (dialog, sender) = (self.dialog.clone(), self.sender.clone());
        glib::spawn_future_local(async move {
            if crate::workspace::respond(&asking, dialog.upcast_ref()).await == DELETE {
                sender.deliver(SessionWindowInput::DeleteTag(id));
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
}

fn carriers(connections: &[SavedConnection], tag: &ConnectionTag) -> usize {
    connections.iter().filter(|saved| saved.tags.contains(&tag.id)).count()
}

fn used_by(count: usize) -> String {
    if count == 0 {
        return crate::i18n::gettext("No connections");
    }
    crate::i18n::ngettext_f(
        "{n} connection",
        "{n} connections",
        u32::try_from(count).unwrap_or(u32::MAX),
        &[("n", &count.to_string())],
    )
}

pub(super) fn delete_alert(tag: &ConnectionTag, count: usize) -> adw::AlertDialog {
    let body = (count > 0).then(|| {
        crate::i18n::ngettext_f(
            "It comes off {n} connection, which stays saved.",
            "It comes off {n} connections, which stay saved.",
            u32::try_from(count).unwrap_or(u32::MAX),
            &[("n", &count.to_string())],
        )
    });
    let dialog = adw::AlertDialog::new(
        Some(&crate::i18n::gettext_f(
            "Delete “{tag}”?",
            &[("tag", tag.name.as_str())],
        )),
        body.as_deref(),
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
        ConnectionColor, ConnectionList, ConnectionListState, ConnectionStore, ConnectionTagName, StoragePaths,
    };
    use uuid::Uuid;

    use super::*;

    fn tag(name: &str) -> ConnectionTag {
        ConnectionTag::new(ConnectionTagName::new(name).expect("a tag name"), ConnectionColor::Red)
    }

    fn connection(tags: &[&ConnectionTag]) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: "acme".to_owned(),
            driver_id: "postgres".to_owned(),
            host: "db".to_owned(),
            port: 5432,
            database: "app".to_owned(),
            username: "app".to_owned(),
            tls: tablepro_core::TlsConfig::verify_full(),
            safe_mode: tablepro_core::SafeModeLevel::Off,
            external_access: tablepro_core::ExternalAccess::ReadOnly,
            ai_policy: tablepro_core::AiPolicy::Ask,
            auth_mode: tablepro_core::AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: None,
            tags: tags.iter().map(|tag| tag.id).collect(),
            icon: None,
            options: Default::default(),
        }
    }

    fn list() -> (Rc<SavedConnectionList>, tempfile::TempDir) {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        (
            SavedConnectionList::follow(&store, std::sync::Arc::new(crate::build_registry())),
            dir,
        )
    }

    fn ready(connections: Vec<SavedConnection>, tags: Vec<ConnectionTag>) -> ConnectionListState {
        ConnectionListState::Ready(ConnectionList::new(Arc::from(connections), Arc::from(tags)))
    }

    #[gtk4::test]
    fn each_tag_shows_with_how_many_connections_carry_it_and_follows_the_list() {
        let _ = adw::init();
        let (list, _dir) = list();
        let (production, acme) = (tag("production"), tag("acme"));
        list.apply(ready(
            vec![connection(&[&production, &acme]), connection(&[&production])],
            vec![production.clone(), acme.clone()],
        ));
        let (sender, _receiver) = crate::runtime::input_queue::<SessionWindowInput>();

        let manage = ManageTagsDialog::new(list.clone(), sender);

        assert_eq!(
            manage.rows(),
            [
                ("acme".to_owned(), "1 connection".to_owned()),
                ("production".to_owned(), "2 connections".to_owned())
            ]
        );
        assert_eq!(manage.page().as_deref(), Some("tags"));
        list.apply(ready(vec![connection(&[])], vec![acme]));
        assert_eq!(manage.rows(), [("acme".to_owned(), "No connections".to_owned())]);
        list.apply(ready(Vec::new(), Vec::new()));
        assert!(manage.rows().is_empty());
        assert_eq!(manage.page().as_deref(), Some("empty"));
    }

    #[gtk4::test]
    fn a_closed_dialog_stops_following_the_list() {
        let _ = adw::init();
        let (list, _dir) = list();
        let (sender, _receiver) = crate::runtime::input_queue::<SessionWindowInput>();
        let manage = ManageTagsDialog::new(list.clone(), sender);
        assert_eq!(manage.page().as_deref(), Some("empty"), "no tags showed a blank page");

        manage.dialog.emit_by_name::<()>("closed", &[]);
        list.apply(ready(Vec::new(), vec![tag("acme")]));

        assert!(manage.rows().is_empty(), "a closed dialog still followed the list");
    }

    #[gtk4::test]
    fn deleting_asks_with_cancel_the_default_and_names_the_count() {
        let _ = adw::init();
        let production = tag("production");

        let used = delete_alert(&production, 3);
        let unused = delete_alert(&production, 0);

        assert_eq!(used.heading().as_deref(), Some("Delete “production”?"));
        assert_eq!(used.body().as_str(), "It comes off 3 connections, which stay saved.");
        assert_eq!(unused.body().as_str(), "");
        assert_eq!(used.default_response().as_deref(), Some(CANCEL));
        assert_eq!(used.response_appearance(DELETE), adw::ResponseAppearance::Destructive);
    }
}
