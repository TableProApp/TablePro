use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::subclass::prelude::*;

use super::ExportJobItem;
use super::export_failure_text::progress_text;
use crate::i18n::gettext;

mod imp {
    use super::*;

    #[derive(Default, gtk::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/export-operations-button.ui")]
    pub struct ExportOperationsButton {
        #[template_child]
        pub menu_button: TemplateChild<gtk::MenuButton>,
        #[template_child]
        pub job_list: TemplateChild<gtk::ListBox>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for ExportOperationsButton {
        const NAME: &'static str = "TableProExportOperationsButton";
        type Type = super::ExportOperationsButton;
        type ParentType = adw::Bin;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for ExportOperationsButton {}
    impl WidgetImpl for ExportOperationsButton {}
    impl BinImpl for ExportOperationsButton {}
}

glib::wrapper! {
    /// The header bar's button for the exports a workspace has running,
    /// with a row for each that shows its progress and stops it.
    pub struct ExportOperationsButton(ObjectSubclass<imp::ExportOperationsButton>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Default for ExportOperationsButton {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl ExportOperationsButton {
    /// List `jobs`, and show the button only while there is one.
    pub(crate) fn bind(&self, jobs: &gio::ListStore) {
        let imp = self.imp();
        imp.job_list.bind_model(Some(jobs), |item| {
            item.downcast_ref::<ExportJobItem>()
                .map_or_else(|| gtk::ListBoxRow::new().upcast(), job_row)
        });
        self.set_visible(jobs.n_items() > 0);
        let button = self.downgrade();
        jobs.connect_items_changed(move |jobs, _, _, _| {
            if let Some(button) = button.upgrade() {
                let running = jobs.n_items() > 0;
                if !running {
                    button.imp().menu_button.popdown();
                }
                button.set_visible(running);
            }
        });
    }

    #[cfg(test)]
    pub(crate) fn job_list(&self) -> gtk::ListBox {
        self.imp().job_list.get()
    }
}

fn job_row(item: &ExportJobItem) -> gtk::Widget {
    let title = gtk::Label::builder()
        .xalign(0.0)
        .ellipsize(gtk::pango::EllipsizeMode::Middle)
        .build();
    item.bind_property("title", &title, "label").sync_create().build();
    let progress = gtk::ProgressBar::new();
    let subtitle = gtk::Label::builder().xalign(0.0).build();
    subtitle.add_css_class("caption");
    subtitle.add_css_class("dim-label");
    let text = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(6)
        .hexpand(true)
        .build();
    text.append(&title);
    text.append(&progress);
    text.append(&subtitle);

    let stop = gtk::Button::from_icon_name(crate::ui::icons::PROCESS_STOP);
    crate::ui::a11y::describe_icon_button(&stop, &gettext("Stop Export"), None);
    stop.set_valign(gtk::Align::Center);
    stop.add_css_class("flat");
    stop.add_css_class("circular");
    let stopping = item.downgrade();
    stop.connect_clicked(move |_| {
        if let Some(item) = stopping.upgrade() {
            item.stop();
        }
    });

    let content = gtk::Box::builder()
        .spacing(12)
        .margin_top(12)
        .margin_bottom(12)
        .margin_start(12)
        .margin_end(12)
        .build();
    content.append(&text);
    content.append(&stop);

    show_progress(item, &progress, &subtitle);
    let (progress_bar, subtitle_label) = (progress.downgrade(), subtitle.downgrade());
    item.connect_rows_notify(move |item| {
        if let (Some(progress), Some(subtitle)) = (progress_bar.upgrade(), subtitle_label.upgrade()) {
            show_progress(item, &progress, &subtitle);
        }
    });

    gtk::ListBoxRow::builder()
        .activatable(false)
        .child(&content)
        .build()
        .upcast()
}

/// A bar that fills when the total is known, and pulses with each
/// chunk written when it is not.
fn show_progress(item: &ExportJobItem, progress: &gtk::ProgressBar, subtitle: &gtk::Label) {
    match item.fraction() {
        Some(fraction) => progress.set_fraction(fraction),
        None if item.rows() > 0 => progress.pulse(),
        None => {}
    }
    subtitle.set_label(&progress_text(item.rows(), item.expected()));
}
