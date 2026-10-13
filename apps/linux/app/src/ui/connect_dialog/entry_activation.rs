use relm4::adw::prelude::*;
use relm4::{adw, gtk};

pub(super) fn connect_entry_activations(container: &impl IsA<gtk::Widget>, submit: impl Fn() + Clone + 'static) {
    let mut pending = vec![container.as_ref().clone().upcast::<gtk::Widget>()];
    while let Some(widget) = pending.pop() {
        if let Ok(row) = widget.clone().downcast::<adw::EntryRow>() {
            let submit = submit.clone();
            row.connect_entry_activated(move |_| submit());
        }
        let mut child = widget.first_child();
        while let Some(current) = child {
            child = current.next_sibling();
            pending.push(current);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::rc::Rc;

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn activating_a_nested_entry_row_invokes_submit() {
        relm4::adw::init().unwrap();
        let container = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let group = adw::PreferencesGroup::new();
        let row = adw::EntryRow::new();
        group.add(&row);
        container.append(&group);
        let submitted = Rc::new(Cell::new(false));
        let submitted_on_activation = submitted.clone();

        connect_entry_activations(&container, move || submitted_on_activation.set(true));
        row.emit_by_name::<()>("entry-activated", &[]);

        assert!(submitted.get());
    }
}
