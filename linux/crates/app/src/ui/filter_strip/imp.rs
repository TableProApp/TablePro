use std::cell::{Cell, OnceCell, RefCell};
use std::rc::Rc;
use std::sync::OnceLock;

use glib::subclass::Signal;
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;
use tablepro_core::ColumnInfo;

use crate::application::{ShortcutOwner, local_shortcut_controller};

#[derive(Default, gtk::CompositeTemplate, glib::Properties)]
#[template(resource = "/app/tablepro/TablePro/ui/filter-strip.ui")]
#[properties(wrapper_type = super::FilterStrip)]
pub struct FilterStrip {
    #[template_child]
    pub revealer: TemplateChild<gtk::Revealer>,
    #[template_child]
    pub match_revealer: TemplateChild<gtk::Revealer>,
    #[template_child]
    pub combinator_dropdown: TemplateChild<gtk::DropDown>,
    #[template_child]
    pub clear_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub apply_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub close_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub raw_entry: TemplateChild<gtk::Entry>,
    #[template_child]
    pub rules_expander: TemplateChild<gtk::Expander>,
    #[template_child]
    pub rule_list: TemplateChild<gtk::ListBox>,
    #[template_child]
    pub add_rule_button: TemplateChild<gtk::Button>,

    /// Slid into view. Escape, Close, Apply and Clear all slide it out.
    #[property(get, set)]
    pub revealed: Cell<bool>,

    /// The rules being edited, one `FilterRuleObject` each.
    pub(super) rules: OnceCell<gio::ListStore>,
    /// The columns a rule can name, blobs left out.
    pub(super) columns: RefCell<Rc<[ColumnInfo]>>,
}

#[glib::object_subclass]
impl ObjectSubclass for FilterStrip {
    const NAME: &'static str = "TableProFilterStrip";
    type Type = super::FilterStrip;
    type ParentType = adw::Bin;

    fn class_init(klass: &mut Self::Class) {
        klass.bind_template();
        klass.install_action("filter.close", None, |strip, _, _| strip.set_revealed(false));
        klass.install_action("filter.apply", None, |strip, _, _| strip.apply());
        klass.install_action("filter.clear", None, |strip, _, _| strip.clear());
        klass.install_action("filter.add-rule", None, |strip, _, _| strip.add_rule());
    }

    fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
        object.init_template();
    }
}

#[glib::derived_properties]
impl ObjectImpl for FilterStrip {
    fn signals() -> &'static [Signal] {
        static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
        SIGNALS.get_or_init(|| {
            vec![
                Signal::builder("applied")
                    .param_types([glib::BoxedAnyObject::static_type()])
                    .build(),
            ]
        })
    }

    fn constructed(&self) {
        self.parent_constructed();
        let strip = self.obj();
        let close = self.close_button.get();
        close.set_icon_name(crate::ui::icons::WINDOW_CLOSE);
        crate::ui::a11y::describe_icon_button(&close, &crate::i18n::gettext("Close"), Some("filter.close"));
        strip.add_controller(local_shortcut_controller(ShortcutOwner::FilterStrip));
        strip.connect_parts();
    }
}

impl WidgetImpl for FilterStrip {}
impl BinImpl for FilterStrip {}
