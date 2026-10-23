//! The Appearance group: the connection's icon and its tags.

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_storage::{ConnectionIcon, ConnectionTag};
use uuid::Uuid;

use super::ConnectDialog;
use crate::ui::connection_appearance::{color_dot, icon_label, leading_factory, show_icon};

impl ConnectDialog {
    /// Fill the icon choices and the tag rows, ticked at `carried`.
    pub(super) fn show_appearance(&self, tags: &[ConnectionTag], icon: Option<ConnectionIcon>, carried: &[Uuid]) {
        let imp = self.imp();
        fill_icon_row(&imp.icon_row);
        imp.icon_row.set_selected(icon_position(icon));
        for tag in tags {
            self.add_tag_row(tag, carried.contains(&tag.id));
        }
        let new_tag = adw::ButtonRow::builder()
            .title(crate::i18n::gettext("New Tag…"))
            .build();
        let weak = self.downgrade();
        new_tag.connect_activated(move |_| {
            if let Some(dialog) = weak.upgrade() {
                dialog.ask_new_tag();
            }
        });
        imp.tags_row.add_row(&new_tag);
        imp.new_tag_row.replace(Some(new_tag));
        self.show_tags_subtitle();
    }

    pub(super) fn picked_icon(&self) -> Option<ConnectionIcon> {
        let selected = usize::try_from(self.imp().icon_row.selected()).ok()?;
        selected
            .checked_sub(1)
            .and_then(|at| ConnectionIcon::ALL.get(at).copied())
    }

    /// The ticked tags, in the list's order.
    pub(super) fn picked_tags(&self) -> Vec<Uuid> {
        self.imp()
            .tag_checks
            .borrow()
            .iter()
            .filter(|(_, check)| check.is_active())
            .map(|(tag, _)| tag.id)
            .collect()
    }

    fn add_tag_row(&self, tag: &ConnectionTag, ticked: bool) {
        let imp = self.imp();
        let check = gtk::CheckButton::builder()
            .active(ticked)
            .valign(gtk::Align::Center)
            .build();
        check.update_property(&[gtk::accessible::Property::Label(tag.name.as_str())]);
        let row = adw::ActionRow::builder()
            .title(tag.name.as_str())
            .use_markup(false)
            .activatable_widget(&check)
            .build();
        row.add_prefix(&check);
        row.add_suffix(&color_dot(Some(tag.color)));
        let weak = self.downgrade();
        check.connect_toggled(move |_| {
            if let Some(dialog) = weak.upgrade() {
                dialog.show_tags_subtitle();
            }
        });
        // Before New Tag…, which stays last.
        match imp.new_tag_row.borrow().as_ref() {
            Some(new_tag) => {
                imp.tags_row.remove(new_tag);
                imp.tags_row.add_row(&row);
                imp.tags_row.add_row(new_tag);
            }
            None => imp.tags_row.add_row(&row),
        }
        imp.tag_checks.borrow_mut().push((tag.clone(), check));
    }

    /// The ticked tags by name, or None, so the row says what it holds
    /// while it is folded.
    fn show_tags_subtitle(&self) {
        let imp = self.imp();
        let names: Vec<String> = imp
            .tag_checks
            .borrow()
            .iter()
            .filter(|(_, check)| check.is_active())
            .map(|(tag, _)| tag.name.as_str().to_owned())
            .collect();
        imp.tags_row.set_subtitle(&if names.is_empty() {
            crate::i18n::pgettext("no tags", "None")
        } else {
            names.join(&crate::i18n::pgettext("list separator", ", "))
        });
    }

    /// Make a tag from the dialog and tick it. The tag exists from then
    /// on, whether or not the connection is saved.
    fn ask_new_tag(&self) {
        let Some(services) = self.services() else {
            return;
        };
        let existing: Vec<ConnectionTag> = self
            .imp()
            .tag_checks
            .borrow()
            .iter()
            .map(|(tag, _)| tag.clone())
            .collect();
        let (editor, tasks, hold) = (services.editor.clone(), services.tasks.clone(), services.hold.clone());
        let weak = self.downgrade();
        glib::spawn_future_local(async move {
            let Some(dialog) = weak.upgrade() else {
                return;
            };
            let Some((name, color)) = crate::ui::tags::ask_new_tag(dialog.upcast_ref(), &existing).await else {
                return;
            };
            let holding = hold.acquire();
            dialog.imp().creating_tag.set(true);
            dialog.refresh();
            let weak = dialog.downgrade();
            crate::runtime::spawn_and_deliver(
                &tasks,
                async move { editor.create_tag(name, color, None).await },
                move |outcome| {
                    drop(holding);
                    let Some(dialog) = weak.upgrade() else {
                        return;
                    };
                    dialog.imp().creating_tag.set(false);
                    dialog.refresh();
                    match outcome {
                        Ok(Ok(tag)) => {
                            dialog.add_tag_row(&tag, true);
                            dialog.show_tags_subtitle();
                        }
                        Ok(Err(error)) => dialog.show_toast(
                            &crate::i18n::gettext_f(
                                "The tag could not be created. {reason}",
                                &[("reason", &crate::ui::error_text::saved_connection_error_message(&error))],
                            ),
                            None,
                        ),
                        Err(failure) => {
                            dialog.show_toast(&crate::ui::error_text::task_failure_message(&failure), None);
                        }
                    }
                },
            );
        });
    }
}

fn icon_position(icon: Option<ConnectionIcon>) -> u32 {
    icon.and_then(|icon| ConnectionIcon::ALL.iter().position(|candidate| *candidate == icon))
        .and_then(|at| u32::try_from(at + 1).ok())
        .unwrap_or(0)
}

/// None, then each icon with its name, the icon shown beside it.
fn fill_icon_row(row: &adw::ComboRow) {
    let names = gtk::StringList::new(&[]);
    names.append(&crate::i18n::pgettext("no icon", "None"));
    for icon in ConnectionIcon::ALL {
        names.append(&icon_label(icon));
    }
    let factory = leading_factory(
        &names,
        || {
            gtk::Image::builder()
                .accessible_role(gtk::AccessibleRole::Presentation)
                .build()
                .upcast()
        },
        |leading, place| {
            let icon = place
                .and_then(|at| at.checked_sub(1))
                .and_then(|at| ConnectionIcon::ALL.get(at).copied());
            if let Some(image) = leading.downcast_ref::<gtk::Image>() {
                show_icon(image, icon);
            }
        },
    );
    row.set_model(Some(&names));
    row.set_factory(Some(&factory));
    row.set_expression(Some(gtk::PropertyExpression::new(
        gtk::StringObject::static_type(),
        None::<gtk::Expression>,
        "string",
    )));
}
