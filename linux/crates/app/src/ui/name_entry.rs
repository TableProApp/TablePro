use libadwaita as adw;
use libadwaita::prelude::*;

/// Keep `response` off while `entry` holds no name, so Enter in the row
/// and the button both wait for one instead of closing on nothing.
pub(crate) fn require_name(dialog: &adw::AlertDialog, response: &str, entry: &adw::EntryRow) {
    let named = |entry: &adw::EntryRow| !entry.text().trim().is_empty();
    dialog.set_response_enabled(response, named(entry));
    let dialog = dialog.downgrade();
    let response = response.to_owned();
    entry.connect_changed(move |entry| {
        if let Some(dialog) = dialog.upgrade() {
            dialog.set_response_enabled(&response, named(entry));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[gtk4::test]
    fn the_response_waits_for_a_name() {
        adw::init().expect("libadwaita initialises under the test backend");
        let dialog = adw::AlertDialog::new(Some("Save Query"), None);
        dialog.add_response("save", "Save");
        let entry = adw::EntryRow::new();
        entry.set_text("  ");

        require_name(&dialog, "save", &entry);
        assert!(!dialog.is_response_enabled("save"), "a blank name can be saved");

        entry.set_text("daily");
        assert!(dialog.is_response_enabled("save"));

        entry.set_text("");
        assert!(!dialog.is_response_enabled("save"));
    }
}
