// The top of each step: art, the step number, a title and one sentence, centered as GNOME Initial Setup does.

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

use crate::i18n::gettext_f;

const STEPS: u32 = 4;

mod imp {
    use std::cell::Cell;
    use std::marker::PhantomData;

    use super::*;

    #[derive(Default, gtk::CompositeTemplate, glib::Properties)]
    #[properties(wrapper_type = super::SetupHero)]
    #[template(resource = "/app/tablepro/TablePro/ui/setup-hero.ui")]
    pub struct SetupHero {
        #[template_child]
        pub art: TemplateChild<gtk::Image>,
        #[template_child]
        pub step_label: TemplateChild<gtk::Label>,
        #[template_child]
        pub title_label: TemplateChild<gtk::Label>,
        #[template_child]
        pub description_label: TemplateChild<gtk::Label>,
        #[property(get = Self::icon_name, set = Self::set_icon_name)]
        icon_name: PhantomData<String>,
        #[property(get = Self::pixel_size, set = Self::set_pixel_size, default = 64)]
        pixel_size: PhantomData<i32>,
        #[property(get = Self::dimmed, set = Self::set_dimmed)]
        dimmed: PhantomData<bool>,
        #[property(get, set = Self::set_step)]
        step: Cell<u32>,
        #[property(get = Self::title, set = Self::set_title)]
        title: PhantomData<String>,
        #[property(get = Self::description, set = Self::set_description)]
        description: PhantomData<String>,
        #[property(get = Self::show_art, set = Self::set_show_art, default = true)]
        show_art: PhantomData<bool>,
    }

    impl SetupHero {
        fn icon_name(&self) -> String {
            self.art.icon_name().map(String::from).unwrap_or_default()
        }

        fn set_icon_name(&self, name: String) {
            self.art.set_icon_name(Some(&name));
        }

        fn pixel_size(&self) -> i32 {
            self.art.pixel_size()
        }

        fn set_pixel_size(&self, size: i32) {
            self.art.set_pixel_size(size);
        }

        fn dimmed(&self) -> bool {
            self.art.has_css_class("dimmed")
        }

        // A symbolic glyph is dimmed; a full-color app icon gets the shadow Adwaita gives large app icons.
        fn set_dimmed(&self, dimmed: bool) {
            if dimmed {
                self.art.remove_css_class("icon-dropshadow");
                self.art.add_css_class("dimmed");
            } else {
                self.art.remove_css_class("dimmed");
                self.art.add_css_class("icon-dropshadow");
            }
        }

        fn set_step(&self, step: u32) {
            self.step.set(step);
            self.step_label.set_label(&gettext_f(
                "Step {n} of {total}",
                &[("n", &step.to_string()), ("total", &STEPS.to_string())],
            ));
        }

        fn title(&self) -> String {
            self.title_label.label().into()
        }

        fn set_title(&self, title: String) {
            self.title_label.set_label(&title);
        }

        fn description(&self) -> String {
            self.description_label.label().into()
        }

        fn set_description(&self, description: String) {
            self.description_label.set_label(&description);
        }

        fn show_art(&self) -> bool {
            self.art.is_visible()
        }

        fn set_show_art(&self, shown: bool) {
            self.art.set_visible(shown);
        }
    }

    #[glib::object_subclass]
    impl ObjectSubclass for SetupHero {
        const NAME: &'static str = "TableProSetupHero";
        type Type = super::SetupHero;
        type ParentType = gtk::Box;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    #[glib::derived_properties]
    impl ObjectImpl for SetupHero {}

    impl WidgetImpl for SetupHero {}
    impl BoxImpl for SetupHero {}
}

glib::wrapper! {
    pub struct SetupHero(ObjectSubclass<imp::SetupHero>)
        @extends gtk::Box, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget, gtk::Orientable;
}
