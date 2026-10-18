use std::sync::OnceLock;

use glib::subclass::Signal;
use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::subclass::prelude::*;

use crate::ui::a11y::announce_key_shortcuts;

/// What a click in the bar asks the tab for, one signal each.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum PendingChangesRequest {
    Save,
    Discard,
    StopSaving,
}

impl PendingChangesRequest {
    const ALL: [Self; 3] = [Self::Save, Self::Discard, Self::StopSaving];

    fn signal(self) -> &'static str {
        match self {
            Self::Save => "save",
            Self::Discard => "discard",
            Self::StopSaving => "stop-saving",
        }
    }
}

mod imp {
    use super::*;

    #[derive(Default, gtk::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/pending-changes-bar.ui")]
    pub struct PendingChangesBar {
        #[template_child]
        pub revealer: TemplateChild<gtk::Revealer>,
        #[template_child]
        pub pending_label: TemplateChild<gtk::Label>,
        #[template_child]
        pub saving_spinner: TemplateChild<adw::Spinner>,
        #[template_child]
        pub save_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub discard_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub stop_button: TemplateChild<gtk::Button>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for PendingChangesBar {
        const NAME: &'static str = "TableProPendingChangesBar";
        type Type = super::PendingChangesBar;
        type ParentType = adw::Bin;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for PendingChangesBar {
        fn constructed(&self) {
            self.parent_constructed();
            self.obj().connect_buttons();
        }

        fn signals() -> &'static [Signal] {
            static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
            SIGNALS.get_or_init(|| {
                PendingChangesRequest::ALL
                    .into_iter()
                    .map(|request| Signal::builder(request.signal()).build())
                    .collect()
            })
        }
    }

    impl WidgetImpl for PendingChangesBar {}
    impl BinImpl for PendingChangesBar {}
}

glib::wrapper! {
    /// The browse tab's footer while it has unsaved changes: how many,
    /// Save and Discard, and Stop Saving while a save runs. It sends
    /// each click back as a signal.
    pub struct PendingChangesBar(ObjectSubclass<imp::PendingChangesBar>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Default for PendingChangesBar {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl PendingChangesBar {
    pub(super) fn connect_request<F: Fn(&Self) + 'static>(
        &self,
        request: PendingChangesRequest,
        f: F,
    ) -> glib::SignalHandlerId {
        self.connect_closure(request.signal(), false, glib::closure_local!(move |bar: &Self| f(bar)))
    }

    pub(super) fn announce_save_keys(&self, group: &str, save: &gio::SimpleAction) {
        announce_key_shortcuts(&self.imp().save_button.get(), &format!("{group}.{}", save.name()));
    }

    pub(super) fn show_pending(&self, count: usize) {
        let imp = self.imp();
        let visible = count > 0;
        if visible {
            let label = if count == 1 {
                crate::i18n::gettext("1 unsaved change")
            } else {
                crate::i18n::ngettext_f(
                    "{n} unsaved change",
                    "{n} unsaved changes",
                    u32::try_from(count).unwrap_or(u32::MAX),
                    &[("n", &count.to_string())],
                )
            };
            crate::ui::a11y::show_status(&imp.pending_label, &label);
        }
        imp.revealer.set_reveal_child(visible);
    }

    /// While a save runs, Save and Discard are off, so a double click
    /// cannot send two, and Stop Saving takes their place, the focus
    /// with it.
    pub(super) fn show_saving(&self, saving: bool) {
        let imp = self.imp();
        let save = imp.save_button.get();
        let stop = imp.stop_button.get();
        if saving {
            imp.saving_spinner.set_visible(true);
            stop.set_visible(true);
            for button in [&save, &imp.discard_button.get()] {
                crate::ui::a11y::pass_focus(button, &stop);
                button.set_sensitive(false);
            }
            crate::ui::a11y::announce(
                &imp.saving_spinner.get(),
                &crate::i18n::gettext("Saving…"),
                gtk::AccessibleAnnouncementPriority::Medium,
            );
        } else {
            save.set_sensitive(true);
            imp.discard_button.set_sensitive(true);
            crate::ui::a11y::pass_focus(&stop, &save);
            stop.set_visible(false);
            imp.saving_spinner.set_visible(false);
        }
    }

    fn connect_buttons(&self) {
        let imp = self.imp();
        for (button, request) in [
            (&imp.save_button, PendingChangesRequest::Save),
            (&imp.discard_button, PendingChangesRequest::Discard),
            (&imp.stop_button, PendingChangesRequest::StopSaving),
        ] {
            let bar = self.downgrade();
            button.connect_clicked(move |_| {
                if let Some(bar) = bar.upgrade() {
                    bar.emit_by_name::<()>(request.signal(), &[]);
                }
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use gtk4::AccessibleProperty;

    use super::*;
    use crate::test_support::SignalLog;

    fn bar() -> PendingChangesBar {
        libadwaita::init().expect("libadwaita initialises under the test backend");
        crate::register_test_resources();
        PendingChangesBar::default()
    }

    #[gtk4::test]
    fn hidden_without_pending_changes() {
        let bar = bar();
        let imp = bar.imp();
        assert!(!imp.revealer.reveals_child());

        bar.show_pending(2);
        assert!(imp.revealer.reveals_child());
        assert_eq!(imp.pending_label.label(), "2 unsaved changes");

        bar.show_pending(0);
        assert!(!imp.revealer.reveals_child());
    }

    #[gtk4::test]
    fn save_announces_the_keys_of_the_action_it_is_given() {
        let bar = bar();
        let save = bar.imp().save_button.get();
        assert!(!gtk::test_accessible_has_property(
            &save,
            AccessibleProperty::KeyShortcuts
        ));

        bar.announce_save_keys("browse", &gio::SimpleAction::new("save", None));

        assert!(gtk::test_accessible_has_property(
            &save,
            AccessibleProperty::KeyShortcuts
        ));
    }

    #[gtk4::test]
    fn save_click_emits_save() {
        let bar = bar();
        let saves = SignalLog::connect(&bar, "save", |_| ());
        let discards = SignalLog::connect(&bar, "discard", |_| ());
        bar.show_pending(1);

        bar.imp().save_button.emit_clicked();

        assert_eq!(saves.count(), 1);
        assert_eq!(discards.count(), 0);
    }

    #[gtk4::test]
    fn stop_saving_visible_only_while_saving() {
        let bar = bar();
        let stops = SignalLog::connect(&bar, "stop-saving", |_| ());
        let imp = bar.imp();
        bar.show_pending(1);
        assert!(!imp.stop_button.is_visible() && !imp.saving_spinner.is_visible());

        bar.show_saving(true);
        assert!(imp.stop_button.is_visible() && imp.saving_spinner.is_visible());
        assert!(!imp.save_button.is_sensitive(), "Save stayed on while a save ran");
        assert!(!imp.discard_button.is_sensitive());
        imp.stop_button.emit_clicked();
        assert_eq!(stops.count(), 1);

        bar.show_saving(false);
        assert!(!imp.stop_button.is_visible() && !imp.saving_spinner.is_visible());
        assert!(imp.save_button.is_sensitive() && imp.discard_button.is_sensitive());
    }

    #[gtk4::test]
    fn the_focus_follows_save_to_stop_saving_and_back() {
        let bar = bar();
        let window = crate::test_support::OwnedWindow::presented(gtk::Window::builder().child(&bar).build());
        let imp = bar.imp();
        bar.show_pending(2);
        assert!(imp.save_button.grab_focus());
        let focus = || gtk::prelude::GtkWindowExt::focus(&*window);

        bar.show_saving(true);
        assert_eq!(focus().as_ref(), Some(imp.stop_button.upcast_ref()));
        assert!(
            crate::ui::a11y::announced_in(&bar)
                .iter()
                .any(|(said, _)| said == "Saving…")
        );

        bar.show_saving(false);
        assert_eq!(focus().as_ref(), Some(imp.save_button.upcast_ref()));
    }

    #[gtk4::test]
    fn a_new_count_of_changes_is_said() {
        let bar = bar();

        bar.show_pending(1);
        bar.show_pending(1);
        bar.show_pending(2);

        let said: Vec<String> = crate::ui::a11y::announced_in(&bar)
            .into_iter()
            .map(|(said, _)| said)
            .collect();
        assert_eq!(said, ["1 unsaved change", "2 unsaved changes"]);
    }
}
