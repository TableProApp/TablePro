use std::collections::HashMap;
use std::rc::Rc;

use gtk::prelude::IsA;
use relm4::adw::prelude::*;
use relm4::{adw, gtk};
use tablepro_core::{ParameterKind, Value};

use crate::services::query_parameters;
use crate::tr;

const RUN_RESPONSE: &str = "run";
const CANCEL_RESPONSE: &str = "cancel";

type ValueSink = Rc<dyn Fn(HashMap<String, Value>)>;

pub fn present<F>(parent: &impl IsA<gtk::Window>, names: &[String], on_values: F)
where
    F: Fn(HashMap<String, Value>) + 'static,
{
    let window = parent.clone().upcast::<gtk::Window>();
    present_form(&window, names.to_vec(), Rc::new(on_values), None);
}

fn present_form(window: &gtk::Window, names: Vec<String>, on_values: ValueSink, error: Option<String>) {
    let dialog = adw::AlertDialog::new(
        Some(&tr!("Query parameters")),
        Some(&tr!("Values are bound by the driver, never pasted into the statement.")),
    );
    dialog.add_response(CANCEL_RESPONSE, &tr!("Cancel"));
    dialog.add_response(RUN_RESPONSE, &tr!("Run with values"));
    dialog.set_response_appearance(RUN_RESPONSE, adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some(RUN_RESPONSE));
    dialog.set_close_response(CANCEL_RESPONSE);

    let kind_labels: Vec<&str> = ParameterKind::ALL.iter().map(|kind| kind.label()).collect();
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .css_classes(["boxed-list"])
        .build();
    let mut rows = Vec::with_capacity(names.len());
    for name in &names {
        let entry = adw::EntryRow::builder().title(format!(":{name}")).build();
        let kinds = gtk::DropDown::from_strings(&kind_labels);
        kinds.set_valign(gtk::Align::Center);
        kinds.set_tooltip_text(Some(&tr!("How the value is sent to the database")));
        entry.add_suffix(&kinds);
        list.append(&entry);
        rows.push((name.clone(), entry, kinds));
    }

    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(12)
        .build();
    content.append(&list);
    if let Some(reason) = &error {
        let label = gtk::Label::builder()
            .label(reason)
            .wrap(true)
            .xalign(0.0)
            .css_classes(["error"])
            .build();
        content.append(&label);
    }
    dialog.set_extra_child(Some(&content));

    let first_entry = rows.first().map(|(_, entry, _)| entry.clone());
    let window_for_retry = window.clone();
    dialog.connect_response(None, move |_, response| {
        if response != RUN_RESPONSE {
            return;
        }
        let entries: Vec<(String, ParameterKind, String)> = rows
            .iter()
            .map(|(name, entry, kinds)| {
                (
                    name.clone(),
                    ParameterKind::from_index(kinds.selected()),
                    entry.text().to_string(),
                )
            })
            .collect();
        match query_parameters::collect_values(&entries) {
            Ok(values) => on_values(values),
            Err(reason) => present_form(&window_for_retry, names.clone(), on_values.clone(), Some(reason)),
        }
    });

    dialog.present(Some(window));
    if let Some(entry) = first_entry {
        entry.grab_focus();
    }
}
