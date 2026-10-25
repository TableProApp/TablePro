use std::cell::{Cell, RefCell};
use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::{adw, gtk};

use tablepro_core::AuthMode;

type ChoiceChanged = Rc<RefCell<Option<Box<dyn Fn(u32)>>>>;

pub(crate) const AUTH_MODE_ROWS: [AuthMode; 2] = [AuthMode::Password, AuthMode::Kerberos];

#[derive(Clone)]
pub(super) struct AccessibleChoice {
    text: gtk::Label,
    selected: Rc<Cell<u32>>,
    labels: Rc<Vec<String>>,
    changed: ChoiceChanged,
    checks: Rc<Vec<gtk::glib::WeakRef<gtk::Image>>>,
}

impl AccessibleChoice {
    pub(super) fn selected(&self) -> u32 {
        self.selected.get()
    }

    pub(super) fn set_selected(&self, selected: u32) {
        self.selected.set(selected);
        for (index, check) in self.checks.iter().enumerate() {
            if let Some(check) = check.upgrade() {
                check.set_opacity(if index as u32 == selected { 1.0 } else { 0.0 });
            }
        }
        self.text.set_text(
            self.labels
                .get(selected as usize)
                .map(String::as_str)
                .unwrap_or_default(),
        );
    }

    pub(super) fn connect_selected_notify(&self, callback: impl Fn(u32) + 'static) {
        *self.changed.borrow_mut() = Some(Box::new(callback));
    }
}

fn dropdown_button(first: Option<&str>) -> (gtk::MenuButton, gtk::Label) {
    let text = gtk::Label::new(first);
    let content = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    content.append(&text);
    content.append(&gtk::Image::from_icon_name("pan-down-symbolic"));
    let button = gtk::MenuButton::builder().child(&content).build();
    button.add_css_class("flat");
    center_in_row(&button);
    (button, text)
}

pub(super) fn center_in_row(widget: &impl IsA<gtk::Widget>) {
    widget.set_valign(gtk::Align::Center);
    widget.set_margin_top(8);
    widget.set_margin_bottom(8);
}

pub(super) fn choice_row(
    title: String,
    subtitle: Option<String>,
    labels: Vec<String>,
) -> (adw::ActionRow, AccessibleChoice) {
    let row = adw::ActionRow::builder().title(&title).build();
    if let Some(subtitle) = subtitle {
        row.set_subtitle(&subtitle);
    }
    let popover = gtk::Popover::new();
    let (button, text) = dropdown_button(labels.first().map(String::as_str));
    let markers: Vec<_> = labels
        .iter()
        .map(|_| gtk::Image::from_icon_name("object-select-symbolic"))
        .collect();
    let selection = AccessibleChoice {
        text,
        selected: Rc::new(Cell::new(0)),
        labels: Rc::new(labels),
        changed: Rc::new(RefCell::new(None)),
        checks: Rc::new(markers.iter().map(ObjectExt::downgrade).collect()),
    };
    let choices = gtk::Box::new(gtk::Orientation::Vertical, 0);
    choices.add_css_class("menu");
    for (index, (label, marker)) in selection.labels.iter().zip(&markers).enumerate() {
        choices.append(&choice_item(label, marker, index as u32, &selection, &popover));
    }
    selection.set_selected(0);
    popover.set_child(Some(&choices));
    button.set_popover(Some(&popover));
    row.add_suffix(&button);
    row.set_activatable_widget(Some(&button));
    (row, selection)
}

fn choice_item(
    label: &str,
    marker: &gtk::Image,
    index: u32,
    selection: &AccessibleChoice,
    popover: &gtk::Popover,
) -> gtk::Button {
    let content = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let text = gtk::Label::builder().label(label).xalign(0.0).hexpand(true).build();
    content.append(&text);
    content.append(marker);
    let choice = gtk::Button::builder().child(&content).halign(gtk::Align::Fill).build();
    choice.add_css_class("flat");
    let selection = selection.clone();
    let popover = popover.downgrade();
    choice.connect_clicked(move |_| {
        selection.set_selected(index);
        if let Some(popover) = popover.upgrade() {
            popover.popdown();
        }
        if let Some(callback) = selection.changed.borrow().as_ref() {
            callback(index);
        }
    });
    choice
}

pub(super) fn timeout_rows() -> (adw::ActionRow, gtk::SpinButton, adw::ActionRow, gtk::SpinButton) {
    let connect = timeout_row(
        &crate::tr!("Connect timeout (seconds)"),
        &crate::tr!("0 uses the default of 30 seconds"),
        600.0,
    );
    let query = timeout_row(
        &crate::tr!("Query timeout (seconds)"),
        &crate::tr!("0 uses the timeout set in Preferences"),
        f64::from(crate::services::operation_control::MAX_QUERY_TIMEOUT_SECS),
    );
    (connect.0, connect.1, query.0, query.1)
}

fn timeout_row(title: &str, subtitle: &str, maximum: f64) -> (adw::ActionRow, gtk::SpinButton) {
    let row = adw::ActionRow::builder().title(title).subtitle(subtitle).build();
    let input = gtk::SpinButton::with_range(0.0, maximum, 1.0);
    center_in_row(&input);
    input.update_property(&[gtk::accessible::Property::Label(title)]);
    row.add_suffix(&input);
    row.set_activatable_widget(Some(&input));
    (row, input)
}

pub(super) fn port_input() -> gtk::SpinButton {
    let port = gtk::SpinButton::with_range(1.0, 65535.0, 1.0);
    port.set_width_chars(6);
    port
}

pub(super) fn timeout_value(seconds: f64) -> Option<u32> {
    let whole = seconds.round();
    (whole >= 1.0).then(|| whole.min(f64::from(u32::MAX)) as u32)
}

pub(super) fn auth_mode_for_row(row: u32) -> AuthMode {
    AUTH_MODE_ROWS.get(row as usize).copied().unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn choice_rows_expose_an_activation_target() {
        gtk::init().unwrap();
        let (row, _) = choice_row("Driver".into(), None, vec!["PostgreSQL".into(), "SQLite".into()]);
        assert!(
            row.activatable_widget().is_some(),
            "keyboard row activation has no target"
        );
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn choice_rows_show_only_the_current_selection() {
        gtk::init().unwrap();
        let (row, selection) = choice_row("Driver".into(), None, vec!["PostgreSQL".into(), "SQLite".into()]);
        let button = row.activatable_widget().unwrap().downcast::<gtk::MenuButton>().unwrap();
        let choices = button.popover().unwrap().child().unwrap();
        let notifications = Rc::new(Cell::new(0));
        let observed = notifications.clone();
        selection.connect_selected_notify(move |_| observed.set(observed.get() + 1));
        selection.set_selected(1);
        assert_eq!(notifications.get(), 0);
        let first = choices.first_child().unwrap().downcast::<gtk::Button>().unwrap();
        let second = first.next_sibling().unwrap().downcast::<gtk::Button>().unwrap();
        let marker = |item: &gtk::Button| {
            item.child()
                .unwrap()
                .downcast::<gtk::Box>()
                .unwrap()
                .last_child()
                .unwrap()
        };
        assert_eq!(marker(&first).opacity(), 0.0);
        assert_eq!(marker(&second).opacity(), 1.0);
        first.emit_clicked();
        assert_eq!(selection.selected(), 0);
        assert_eq!(notifications.get(), 1);
        assert_eq!(marker(&first).opacity(), 1.0);
        assert_eq!(marker(&second).opacity(), 0.0);
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn dropping_a_choice_row_releases_its_popup() {
        gtk::init().unwrap();
        let (row, selection) = choice_row("Driver".into(), None, vec!["PostgreSQL".into()]);
        let button = row.activatable_widget().unwrap().downcast::<gtk::MenuButton>().unwrap();
        let popup = button.popover().unwrap().downgrade();
        drop(button);
        drop(row);
        drop(selection);
        assert!(popup.upgrade().is_none(), "discarded choice row retains its popup");
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn port_input_reserves_room_for_a_five_digit_port() {
        gtk::init().unwrap();
        let port = port_input();
        port.set_value(65535.0);
        assert_eq!(
            port.width_chars(),
            6,
            "maximum TCP port does not have a readable margin"
        );
    }

    #[test]
    fn a_zero_timeout_means_use_the_default() {
        assert_eq!(timeout_value(0.0), None);
        assert_eq!(timeout_value(0.4), None);
        assert_eq!(timeout_value(45.0), Some(45));
    }

    #[test]
    fn auth_mode_rows_decode_to_their_modes() {
        assert_eq!(auth_mode_for_row(0), AuthMode::Password);
        assert_eq!(auth_mode_for_row(1), AuthMode::Kerberos);
        assert_eq!(auth_mode_for_row(7), AuthMode::Password);
    }
}
