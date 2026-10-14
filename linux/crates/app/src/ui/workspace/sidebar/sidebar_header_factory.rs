use std::rc::Weak;

use gtk4 as gtk;
use gtk4::prelude::*;

use super::sidebar_menu::{GROUP, NEW_TABLE};
use super::sidebar_object::SidebarObject;
use super::sidebar_view::SidebarInner;
use crate::ui::a11y::describe_icon_button;

/// A schema's heading, with its New Table button where the connection
/// creates tables. ClickHouse does not: a table there needs an engine and
/// a sorting key the structure tab has no place for, so the button would
/// only fail.
pub(super) fn header_factory(view: Weak<SidebarInner>) -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, object| {
        let Some(header) = object.downcast_ref::<gtk::ListHeader>() else {
            return;
        };
        let row = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(6)
            .margin_top(12)
            .margin_bottom(6)
            .margin_start(12)
            .margin_end(12)
            .build();
        let title = gtk::Label::builder().xalign(0.0).hexpand(true).build();
        // GtkPlacesSidebar's section header: small, bold and dim.
        title.add_css_class("caption-heading");
        title.add_css_class("dimmed");
        let add = gtk::Button::builder()
            .icon_name(crate::ui::icons::LIST_ADD)
            .valign(gtk::Align::Center)
            .build();
        add.add_css_class("flat");
        // The target first, or GTK warns that the action takes one.
        add.set_action_target_value(Some(&None::<String>.to_variant()));
        add.set_action_name(Some(&format!("{GROUP}.{NEW_TABLE}")));
        row.append(&title);
        row.append(&add);
        header.set_child(Some(&row));
    });
    factory.connect_bind(move |_, object| {
        let Some(header) = object.downcast_ref::<gtk::ListHeader>() else {
            return;
        };
        let (Some(row), Some(object)) = (header.child(), header.item().and_downcast::<SidebarObject>()) else {
            return;
        };
        let title = object.section_title();
        if let Some(label) = row.first_child().and_downcast::<gtk::Label>() {
            label.set_label(&title);
        }
        let Some(add) = row.last_child().and_downcast::<gtk::Button>() else {
            return;
        };
        let offered = view.upgrade().is_some_and(|view| view.affordances().offers_new_table());
        add.set_visible(offered);
        let schema = object.schema();
        add.set_action_target_value(Some(&schema.to_variant()));
        // The label says which schema the table goes in.
        let label = match schema {
            Some(_) => crate::i18n::gettext_f("New Table in {schema}…", &[("schema", &title)]),
            None => crate::i18n::gettext("New Table…"),
        };
        describe_icon_button(&add, &label, None);
    });
    factory
}
