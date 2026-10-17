use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use tablepro_core::credentials::SecretKind;

use super::connect_failure_view::ConnectFailureView;

mod imp {
    use super::*;
    use libadwaita::subclass::prelude::*;

    #[derive(Default, gtk::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/connect-failed-page.ui")]
    pub struct ConnectFailedPage {
        #[template_child]
        pub toast_overlay: TemplateChild<adw::ToastOverlay>,
        #[template_child]
        pub header_bar: TemplateChild<adw::HeaderBar>,
        #[template_child]
        pub status_page: TemplateChild<adw::StatusPage>,
        #[template_child]
        pub reenter_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub retry_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub edit_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub choose_button: TemplateChild<gtk::Button>,
        #[cfg(test)]
        pub announced: std::cell::RefCell<Vec<(String, gtk::AccessibleAnnouncementPriority)>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for ConnectFailedPage {
        const NAME: &'static str = "TableProConnectFailedPage";
        type Type = super::ConnectFailedPage;
        type ParentType = adw::Bin;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for ConnectFailedPage {}
    impl WidgetImpl for ConnectFailedPage {}
    impl BinImpl for ConnectFailedPage {}
}

glib::wrapper! {
    /// A connect that failed: why, and Enter Password, Retry, Edit
    /// Connection and Choose Connection as the ways on.
    pub struct ConnectFailedPage(ObjectSubclass<imp::ConnectFailedPage>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl ConnectFailedPage {
    /// `edit_label` names the button that opens the connect dialog,
    /// shown when `view` says the dialog can edit what failed. `reenter`
    /// is the secret the server refused, which the user is offered to
    /// type again.
    pub(crate) fn new(
        view: &ConnectFailureView,
        edit_label: &str,
        reenter: Option<SecretKind>,
        app: Option<&gtk::Application>,
    ) -> Self {
        let page: Self = glib::Object::new();
        let imp = page.imp();
        imp.header_bar.pack_end(&crate::ui::shell::primary_menu_button(app));
        imp.status_page.set_icon_name(Some(crate::ui::icons::NETWORK_ERROR));
        if let Some(heading) = &view.heading {
            imp.status_page.set_title(heading);
        }
        // The description is markup, and the reason quotes server text,
        // file paths and host names.
        imp.status_page
            .set_description(Some(&glib::markup_escape_text(&view.message)));
        imp.edit_button.set_label(edit_label);
        imp.edit_button.set_visible(view.can_edit);
        if let Some(kind) = reenter {
            imp.reenter_button.set_label(&super::secret_retry::reenter_label(kind));
            imp.reenter_button
                .set_action_target_value(Some(&kind.attribute().to_variant()));
            imp.reenter_button.set_visible(true);
            imp.retry_button.remove_css_class("suggested-action");
        }
        page
    }

    /// Say why the connect failed, once the page is in its window: the
    /// page replaces the window's content without moving the focus, so
    /// a screen reader hears this rather than what it read before. Enter
    /// takes the suggested way on.
    pub fn show(&self) {
        let imp = self.imp();
        let heading = imp.status_page.title();
        if let Some(window) = self.root().and_downcast::<gtk::Window>() {
            window.set_title(Some(&heading));
            window.set_default_widget(Some(&self.suggested_button()));
        }
        let message = imp.status_page.description().unwrap_or_default();
        let announcement = format!("{heading}. {message}");
        let priority = gtk::AccessibleAnnouncementPriority::High;
        #[cfg(test)]
        imp.announced.borrow_mut().push((announcement.clone(), priority));
        // libadwaita's own Accessible impls sit behind a feature left off,
        // and every widget is one.
        imp.status_page
            .upcast_ref::<gtk::Widget>()
            .announce(&announcement, priority);
    }

    /// Enter Password when the server refused one, which Retry would
    /// only send again; Retry otherwise.
    fn suggested_button(&self) -> gtk::Button {
        let imp = self.imp();
        if imp.reenter_button.is_visible() {
            imp.reenter_button.get()
        } else {
            imp.retry_button.get()
        }
    }

    pub fn toast_overlay(&self) -> adw::ToastOverlay {
        self.imp().toast_overlay.get()
    }

    /// The reason as the page shows it.
    #[cfg(test)]
    pub fn message(&self) -> Option<String> {
        crate::test_support::status_page_description(&self.imp().status_page)
    }

    /// The button that types a refused secret again, while it shows.
    #[cfg(test)]
    pub fn reenter_button(&self) -> Option<gtk::Button> {
        let button = self.imp().reenter_button.get();
        button.is_visible().then_some(button)
    }

    #[cfg(test)]
    pub fn status_page(&self) -> adw::StatusPage {
        self.imp().status_page.get()
    }

    /// Retry, Edit Connection and Choose Connection, in that order.
    #[cfg(test)]
    pub fn buttons(&self) -> [gtk::Button; 3] {
        let imp = self.imp();
        [imp.retry_button.get(), imp.edit_button.get(), imp.choose_button.get()]
    }

    #[cfg(test)]
    pub fn announced(&self) -> Vec<(String, gtk::AccessibleAnnouncementPriority)> {
        self.imp().announced.borrow().clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn page(heading: Option<&str>) -> ConnectFailedPage {
        let _ = adw::init();
        crate::register_test_resources();
        let view = ConnectFailureView {
            message: "The saved connections could not be written: the disk is full".to_owned(),
            can_edit: true,
            heading: heading.map(str::to_owned),
        };
        ConnectFailedPage::new(&view, "Edit Connection…", None, None)
    }

    #[gtk4::test]
    fn a_save_that_failed_after_the_connect_is_not_called_a_failed_connect() {
        assert_eq!(page(None).status_page().title(), "Could Not Connect");
        assert_eq!(
            page(Some("Could Not Save the Connection")).status_page().title(),
            "Could Not Save the Connection"
        );
    }
}
