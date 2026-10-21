use relm4::adw::{self, prelude::*};

pub(super) fn row() -> adw::EntryRow {
    let row = adw::EntryRow::builder()
        .title(crate::tr!("Authentication database (optional)"))
        .visible(false)
        .build();
    row.set_tooltip_text(Some(&crate::tr!(
        "The database holding the user, for example admin. Leave empty to authenticate against the Database above."
    )));
    row
}

pub(super) fn value(row: &adw::EntryRow) -> Option<String> {
    let text = row.text();
    let text = text.trim();
    (row.is_visible() && !text.is_empty()).then(|| text.to_string())
}

pub(super) fn set(row: &adw::EntryRow, saved: &tablepro_storage::SavedConnection) {
    row.set_text(saved.auth_source.as_deref().unwrap_or_default());
}
