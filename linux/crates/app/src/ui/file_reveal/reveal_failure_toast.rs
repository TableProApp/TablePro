use gtk4::glib;
use libadwaita as adw;

use crate::i18n::gettext;

/// What to tell the user when the file manager could not show the file.
/// The error is logged; its text is the platform's, not ours.
pub(crate) fn reveal_failure_toast(result: &Result<(), glib::Error>) -> Option<adw::Toast> {
    let Err(error) = result else {
        return None;
    };
    tracing::warn!(%error, "could not show a file in the file manager");
    let toast = adw::Toast::new(&gettext("Could not show the file in Files"));
    toast.set_use_markup(false);
    Some(toast)
}

#[cfg(test)]
mod tests {
    use gtk4::gio;

    use super::*;

    #[gtk4::test]
    fn failed_reveal_produces_toast() {
        let failed = Err(glib::Error::new(gio::IOErrorEnum::NotSupported, "no file manager"));

        let toast = reveal_failure_toast(&failed).expect("a toast");

        assert_eq!(toast.title().as_deref(), Some("Could not show the file in Files"));
        assert!(!toast.uses_markup());
        assert!(
            reveal_failure_toast(&Ok(())).is_none(),
            "a reveal that worked made a toast"
        );
    }
}
