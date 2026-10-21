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
}

impl AccessibleChoice {
    pub(super) fn selected(&self) -> u32 {
        self.selected.get()
    }

    pub(super) fn set_selected(&self, selected: u32) {
        self.selected.set(selected);
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

fn dropdown_button(first: Option<&str>) -> (gtk::Button, gtk::Label) {
    let text = gtk::Label::new(first);
    let content = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    content.append(&text);
    content.append(&gtk::Image::from_icon_name("pan-down-symbolic"));
    let button = gtk::Button::builder().child(&content).build();
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
    let labels = Rc::new(labels);
    let selected = Rc::new(Cell::new(0));
    let changed: ChoiceChanged = Rc::new(RefCell::new(None));
    let popover = gtk::Popover::new();
    let (button, text) = dropdown_button(labels.first().map(String::as_str));
    let text_ref = text.downgrade();
    let choices = gtk::Box::new(gtk::Orientation::Vertical, 0);
    choices.add_css_class("menu");
    for (index, label) in labels.iter().enumerate() {
        let choice = gtk::Button::with_label(label);
        choice.add_css_class("flat");
        choice.set_halign(gtk::Align::Fill);
        let selection = selected.clone();
        let labels_ref = labels.clone();
        let changed_ref = changed.clone();
        let popover_ref = popover.downgrade();
        let text_ref = text_ref.clone();
        choice.connect_clicked(move |_| {
            selection.set(index as u32);
            if let Some(text) = text_ref.upgrade() {
                text.set_text(labels_ref.get(index).map(String::as_str).unwrap_or_default());
            }
            if let Some(popover) = popover_ref.upgrade() {
                popover.popdown();
            }
            if let Some(callback) = changed_ref.borrow().as_ref() {
                callback(index as u32);
            }
        });
        choices.append(&choice);
    }
    popover.set_child(Some(&choices));
    popover.set_parent(&button);
    let popup = popover.downgrade();
    button.connect_clicked(move |_| {
        if let Some(popover) = popup.upgrade() {
            popover.popup();
        }
    });
    row.add_suffix(&button);
    (
        row,
        AccessibleChoice {
            text,
            selected,
            labels,
            changed,
        },
    )
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
