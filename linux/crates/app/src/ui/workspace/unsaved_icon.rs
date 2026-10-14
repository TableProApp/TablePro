use libadwaita as adw;

use crate::ui::icons::DOCUMENT_MODIFIED;

/// Mark a tab with unsaved changes by its page icon, as GNOME Text Editor
/// does, never by its title or needs-attention, which the tab bar draws
/// as a call to look at it.
pub(crate) fn apply_unsaved_icon(page: &adw::TabPage, unsaved: bool) {
    match unsaved {
        true => page.set_icon(Some(&gio::ThemedIcon::new(DOCUMENT_MODIFIED))),
        false => page.set_icon(None::<&gio::Icon>),
    }
}
