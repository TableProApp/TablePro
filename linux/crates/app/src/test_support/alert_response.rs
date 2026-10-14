use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;

/// Answer the presented `dialog` with `response` by clicking its button.
/// Emitting `response` by hand would skip the close a click makes first,
/// and with it the `closed` that reaches handlers before the response.
pub(crate) fn respond(dialog: &adw::AlertDialog, response: &str) {
    assert!(
        click_response(dialog, response),
        "the dialog has no “{response}” button"
    );
}

/// Click the button for `response` in `dialog`. False when it has none.
pub(crate) fn click_response(dialog: &adw::AlertDialog, response: &str) -> bool {
    if !dialog.has_response(response) {
        return false;
    }
    let label = dialog.response_label(response);
    let Some(button) = super::descendants(dialog)
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk4::Button>().ok())
        .find(|button| button.label().as_deref() == Some(label.as_str()))
    else {
        return false;
    };
    button.emit_clicked();
    true
}
