use std::cell::RefCell;
use std::rc::Rc;

use gtk::prelude::IsA;
use relm4::adw::prelude::*;
use relm4::gtk::glib;
use relm4::{adw, gtk};

use crate::services::quick_switcher::{QuickItem, QuickTarget, filter};
use crate::tr;

pub fn present<F>(parent: &impl IsA<gtk::Window>, items: Vec<QuickItem>, on_choice: F)
where
    F: Fn(QuickTarget) + 'static,
{
    let window = adw::Window::builder()
        .title(tr!("Open quickly"))
        .transient_for(parent)
        .modal(true)
        .default_width(560)
        .default_height(420)
        .build();

    let search = gtk::SearchEntry::builder()
        .placeholder_text(tr!(
            "Search favorites, tabs, connections and tables. Type > for commands"
        ))
        .hexpand(true)
        .build();
    search.update_property(&[gtk::accessible::Property::Label("Open quickly search")]);
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::Single)
        .css_classes(["boxed-list"])
        .build();
    let scrolled = gtk::ScrolledWindow::builder()
        .child(&list)
        .hexpand(true)
        .vexpand(true)
        .build();

    let empty = adw::StatusPage::builder()
        .icon_name("system-search-symbolic")
        .title(tr!("Nothing matches"))
        .description(tr!("Save a query as a favorite, or open a tab to switch to it."))
        .build();
    let stack = gtk::Stack::new();
    stack.add_named(&scrolled, Some("results"));
    stack.add_named(&empty, Some("empty"));

    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(12)
        .margin_top(12)
        .margin_bottom(12)
        .margin_start(12)
        .margin_end(12)
        .build();
    content.append(&search);
    content.append(&stack);

    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.set_content(Some(&content));
    window.set_content(Some(&toolbar));

    let visible: Rc<RefCell<Vec<QuickItem>>> = Rc::new(RefCell::new(Vec::new()));
    let on_choice: Rc<dyn Fn(QuickTarget)> = Rc::new(on_choice);

    let activate = {
        let window = window.clone();
        let visible = visible.clone();
        let on_choice = on_choice.clone();
        Rc::new(move |index: usize| {
            let target = visible.borrow().get(index).map(|item| item.target.clone());
            if let Some(target) = target {
                window.close();
                on_choice(target);
            }
        })
    };

    let rebuild = {
        let list = list.clone();
        let stack = stack.clone();
        let items = items.clone();
        let visible = visible.clone();
        let activate = activate.clone();
        Rc::new(move |needle: &str| {
            let matched = filter(&items, needle);
            while let Some(child) = list.first_child() {
                list.remove(&child);
            }
            for (index, item) in matched.iter().enumerate() {
                let row = adw::ActionRow::builder()
                    .title(glib::markup_escape_text(&item.title))
                    .subtitle(glib::markup_escape_text(&item.subtitle))
                    .activatable(true)
                    .build();
                let icon = match item.target {
                    QuickTarget::Favorite(_) => "starred-symbolic",
                    QuickTarget::Tab(_) => "tab-new-symbolic",
                    QuickTarget::Connection(_) => "network-server-symbolic",
                    QuickTarget::Relation { .. } => "view-list-symbolic",
                    QuickTarget::Command(_) => "system-run-symbolic",
                };
                row.add_prefix(&gtk::Image::from_icon_name(icon));
                let open_label = tr!("Open {name}").replace("{name}", &item.title);
                let open = gtk::Button::builder()
                    .icon_name("go-next-symbolic")
                    .tooltip_text(&open_label)
                    .valign(gtk::Align::Center)
                    .css_classes(["flat"])
                    .build();
                open.update_property(&[gtk::accessible::Property::Label(&open_label)]);
                let activate_for_button = activate.clone();
                open.connect_clicked(move |_| activate_for_button(index));
                row.add_suffix(&open);
                list.append(&row);
            }
            stack.set_visible_child_name(if matched.is_empty() { "empty" } else { "results" });
            if let Some(first) = list.first_child().and_downcast::<gtk::ListBoxRow>() {
                list.select_row(Some(&first));
            }
            *visible.borrow_mut() = matched;
        })
    };
    rebuild("");

    let rebuild_for_search = rebuild.clone();
    search.connect_search_changed(move |entry| rebuild_for_search(entry.text().as_str()));

    let activate_for_row = activate.clone();
    list.connect_row_activated(move |_, row| activate_for_row(row.index().max(0) as usize));

    let activate_for_entry = activate.clone();
    let list_for_entry = list.clone();
    search.connect_activate(move |_| {
        let index = list_for_entry
            .selected_row()
            .map(|row| row.index().max(0) as usize)
            .unwrap_or(0);
        activate_for_entry(index);
    });

    let list_for_keys = list.clone();
    let keys = gtk::EventControllerKey::new();
    keys.connect_key_pressed(move |_, keyval, _, _| match keyval {
        gtk::gdk::Key::Down => {
            move_selection(&list_for_keys, 1);
            glib::Propagation::Stop
        }
        gtk::gdk::Key::Up => {
            move_selection(&list_for_keys, -1);
            glib::Propagation::Stop
        }
        _ => glib::Propagation::Proceed,
    });
    search.add_controller(keys);

    let window_for_escape = window.clone();
    let escape = gtk::EventControllerKey::new();
    escape.connect_key_pressed(move |_, keyval, _, _| {
        if keyval == gtk::gdk::Key::Escape {
            window_for_escape.close();
            return glib::Propagation::Stop;
        }
        glib::Propagation::Proceed
    });
    window.add_controller(escape);

    window.present();
    search.grab_focus();
}

fn move_selection(list: &gtk::ListBox, delta: i32) {
    let current = list.selected_row().map(|row| row.index()).unwrap_or(0);
    let next = (current + delta).max(0);
    if let Some(row) = list.row_at_index(next) {
        list.select_row(Some(&row));
    }
}
