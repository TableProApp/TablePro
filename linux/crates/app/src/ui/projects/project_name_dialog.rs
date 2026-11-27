use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_storage::{ConnectionProjectName, ProjectNameError, StorageError};

use crate::ui::form_dialog::mark_invalid;

const CANCEL: &str = "cancel";
const SAVE: &str = "save";

pub(crate) async fn ask_new_project(
    parent: &gtk::Widget,
    taken: Vec<ConnectionProjectName>,
) -> Option<ConnectionProjectName> {
    let form = NameForm::new(
        &crate::i18n::gettext("New Project"),
        &crate::i18n::gettext("Create"),
        taken,
        None,
    );
    form.ask(parent).await
}

// `taken` leaves the project itself out, so a change of case alone can be saved.
pub(crate) async fn ask_project_rename(
    parent: &gtk::Widget,
    taken: Vec<ConnectionProjectName>,
    current: &ConnectionProjectName,
) -> Option<ConnectionProjectName> {
    let form = NameForm::new(
        &crate::i18n::gettext("Rename Project"),
        &crate::i18n::gettext("Rename"),
        taken,
        Some(current.clone()),
    );
    form.ask(parent).await
}

// The confirm response stays off for a name the store would refuse, and the reason shows under the name.
struct NameForm {
    dialog: adw::AlertDialog,
    entry: adw::EntryRow,
    #[cfg(test)]
    problem: gtk::Label,
}

impl NameForm {
    fn new(
        heading: &str,
        confirm: &str,
        taken: Vec<ConnectionProjectName>,
        current: Option<ConnectionProjectName>,
    ) -> Self {
        let dialog = adw::AlertDialog::new(Some(heading), None);
        let entry = adw::EntryRow::builder()
            .title(crate::i18n::gettext("Name"))
            .use_markup(false)
            .activates_default(true)
            .build();
        let rows = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).build();
        rows.add_css_class("boxed-list");
        rows.append(&entry);
        let problem = gtk::Label::builder().xalign(0.0).wrap(true).visible(false).build();
        problem.add_css_class("caption");
        problem.add_css_class("error");
        let content = gtk::Box::new(gtk::Orientation::Vertical, 6);
        content.append(&rows);
        content.append(&problem);
        dialog.set_extra_child(Some(&content));
        dialog.add_response(CANCEL, &crate::i18n::gettext("Cancel"));
        dialog.add_response(SAVE, confirm);
        dialog.set_response_appearance(SAVE, adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some(SAVE));
        dialog.set_close_response(CANCEL);
        dialog.set_response_enabled(SAVE, false);
        dialog.set_focus(Some(&entry));
        let (answering, shown, initial) = (dialog.downgrade(), problem.clone(), current.clone());
        entry.connect_changed(move |entry| {
            let typed = entry.text();
            let fault = named(&typed, &taken, current.as_ref())
                .err()
                .and_then(|code| name_problem(code, typed.trim()));
            mark_invalid(entry, fault.as_deref());
            match &fault {
                // Said once per problem: Enter does nothing until it is fixed.
                Some(text) if !shown.is_visible() || shown.label() != text.as_str() => {
                    shown.set_label(text);
                    shown.set_visible(true);
                    crate::ui::a11y::announce(&shown, text, gtk::AccessibleAnnouncementPriority::Medium);
                }
                Some(_) => {}
                None => shown.set_visible(false),
            }
            if let Some(dialog) = answering.upgrade() {
                dialog.set_response_enabled(SAVE, named(&typed, &taken, current.as_ref()).is_ok());
            }
        });
        if let Some(initial) = &initial {
            entry.set_text(initial.as_str());
        }
        Self {
            dialog,
            entry,
            #[cfg(test)]
            problem,
        }
    }

    async fn ask(self, parent: &gtk::Widget) -> Option<ConnectionProjectName> {
        if crate::workspace::respond(&self.dialog, parent).await != SAVE {
            return None;
        }
        ConnectionProjectName::new(&self.entry.text()).ok()
    }

    #[cfg(test)]
    fn problem(&self) -> Option<String> {
        self.problem.is_visible().then(|| self.problem.label().to_string())
    }
}

// The name to save, or the core's code for why there is none.
fn named(
    typed: &str,
    taken: &[ConnectionProjectName],
    current: Option<&ConnectionProjectName>,
) -> Result<ConnectionProjectName, &'static str> {
    let name = ConnectionProjectName::new(typed).map_err(|error| error.code())?;
    if current == Some(&name) {
        return Err(UNCHANGED);
    }
    if taken.iter().any(|other| other.same_name(&name)) {
        return Err(StorageError::ProjectNameTaken { name: String::new() }.code());
    }
    Ok(name)
}

const UNCHANGED: &str = "unchanged";

// `None` for a name there is nothing to say about yet: an empty one, or the one it already has.
fn name_problem(code: &str, typed: &str) -> Option<String> {
    if code == ProjectNameError::ControlCharacter.code() {
        return Some(crate::i18n::gettext(
            "A project name cannot contain control characters.",
        ));
    }
    if code == (StorageError::ProjectNameTaken { name: String::new() }).code() {
        return Some(crate::i18n::gettext_f(
            "A project named “{name}” already exists.",
            &[("name", typed)],
        ));
    }
    None
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use gtk4::glib;

    use super::*;
    use crate::test_support::{OwnedWindow, wait_until};

    const WAIT: std::time::Duration = std::time::Duration::from_secs(10);

    fn name(text: &str) -> ConnectionProjectName {
        ConnectionProjectName::new(text).expect("a project name")
    }

    #[gtk4::test]
    fn create_stays_off_for_a_name_the_store_would_refuse_and_says_why() {
        let _ = adw::init();
        let form = NameForm::new("New Project", "Create", vec![name("Acme")], None);

        assert_eq!(form.dialog.heading().as_deref(), Some("New Project"));
        assert!(!form.dialog.is_response_enabled(SAVE), "an empty name can be saved");
        assert_eq!(form.problem(), None, "an empty form already shows a problem");
        for (typed, usable, problem) in [
            ("   ", false, None),
            ("acme", false, Some("A project named “acme” already exists.")),
            (" ACME ", false, Some("A project named “ACME” already exists.")),
            (
                "Ac\u{7}me",
                false,
                Some("A project name cannot contain control characters."),
            ),
            ("Acme 2", true, None),
        ] {
            form.entry.set_text(typed);
            assert_eq!(form.dialog.is_response_enabled(SAVE), usable, "{typed:?}");
            assert_eq!(form.problem().as_deref(), problem, "{typed:?}");
            assert_eq!(form.entry.has_css_class("error"), problem.is_some(), "{typed:?}");
        }
        assert_eq!(form.dialog.default_response().as_deref(), Some(SAVE));
        assert_eq!(form.dialog.close_response(), CANCEL);
    }

    #[gtk4::test]
    fn a_rename_takes_a_change_of_case_and_not_the_name_it_has() {
        let _ = adw::init();
        let form = NameForm::new("Rename Project", "Rename", vec![name("Side")], Some(name("Acme")));

        assert_eq!(form.entry.text().as_str(), "Acme");
        assert!(!form.dialog.is_response_enabled(SAVE), "an unchanged name can be saved");
        assert_eq!(form.problem(), None);
        form.entry.set_text("ACME");
        assert!(form.dialog.is_response_enabled(SAVE));
        form.entry.set_text("side");
        assert!(!form.dialog.is_response_enabled(SAVE));
        assert_eq!(
            form.problem().as_deref(),
            Some("A project named “side” already exists.")
        );
    }

    #[gtk4::test]
    fn the_typed_name_is_the_answer_and_a_cancelled_dialog_answers_nothing() {
        let _ = adw::init();
        let window = OwnedWindow::presented(adw::Window::new());
        let parent: gtk::Widget = (*window).clone().upcast();
        let ask = |parent: gtk::Widget| {
            let answer = Rc::new(RefCell::new(None));
            let sink = answer.clone();
            glib::spawn_future_local(async move {
                sink.replace(Some(ask_new_project(&parent, vec![name("Acme")]).await));
            });
            answer
        };
        let shown = |window: &adw::Window| {
            let mut dialog = None;
            wait_until(WAIT, || {
                dialog = crate::workspace::visible_alert(window);
                dialog.is_some()
            })
            .expect("the dialog");
            dialog.expect("the dialog")
        };

        let answer = ask(parent.clone());
        let dialog = shown(&window);
        let entry = crate::test_support::descendants(&dialog)
            .into_iter()
            .find_map(|widget| widget.downcast::<adw::EntryRow>().ok())
            .expect("the name row");
        entry.set_text("  Side gig ");
        crate::test_support::respond(&dialog, SAVE);
        wait_until(WAIT, || answer.borrow().is_some()).expect("an answer");
        assert_eq!(answer.borrow().clone(), Some(Some(name("Side gig"))));

        wait_until(WAIT, || crate::workspace::visible_alert(&*window).is_none()).expect("the dialog to go");
        let answer = ask(parent);
        crate::test_support::respond(&shown(&window), CANCEL);
        wait_until(WAIT, || answer.borrow().is_some()).expect("an answer");
        assert_eq!(answer.borrow().clone(), Some(None));
    }
}
