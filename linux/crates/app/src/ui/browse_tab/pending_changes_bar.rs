use std::sync::OnceLock;

use glib::subclass::Signal;
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
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
            announce_key_shortcuts(&self.save_button.get(), "browse.save");
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
            imp.pending_label.set_label(&label);
        }
        imp.revealer.set_reveal_child(visible);
    }

    /// While a save runs, Save and Discard are off, so a double click
    /// cannot send two, and Stop Saving takes their place.
    pub(super) fn show_saving(&self, saving: bool) {
        let imp = self.imp();
        imp.save_button.set_sensitive(!saving);
        imp.discard_button.set_sensitive(!saving);
        imp.saving_spinner.set_visible(saving);
        imp.stop_button.set_visible(saving);
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
}
