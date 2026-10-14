use gtk4::prelude::*;
use gtk4::{gdk, glib};
use thiserror::Error;

use super::ClipboardPayload;

#[derive(Debug, Error)]
pub(crate) enum ClipboardError {
    /// The text type is a C string, so a NUL would cut the copy short,
    /// and a cut copy pasted back would change the value without a word.
    #[error("the text holds a NUL character")]
    ContainsNul,
    #[error("the clipboard refused the copy: {0}")]
    Refused(glib::BoolError),
}

impl ClipboardError {
    pub(crate) fn message(&self) -> String {
        match self {
            Self::ContainsNul => crate::i18n::gettext("Values with a NUL character can't be copied"),
            Self::Refused(_) => crate::i18n::gettext("Couldn't copy to the clipboard"),
        }
    }
}

/// Put `payload` on the clipboard as its own type and as plain text, so
/// an application that knows the type takes it, and any other gets the
/// text.
pub(crate) fn write(clipboard: &gdk::Clipboard, payload: &ClipboardPayload) -> Result<(), ClipboardError> {
    if payload.text.contains('\0') {
        return Err(ClipboardError::ContainsNul);
    }
    let Some(mime_type) = payload.format.mime_type() else {
        clipboard.set_text(&payload.text);
        return Ok(());
    };
    let bytes = glib::Bytes::from_owned(payload.text.clone().into_bytes());
    let provider = gdk::ContentProvider::new_union(&[
        gdk::ContentProvider::for_bytes(mime_type, &bytes),
        gdk::ContentProvider::for_value(&payload.text.to_value()),
    ]);
    clipboard.set_content(Some(&provider)).map_err(|error| {
        tracing::warn!(%error, "the clipboard refused a copy");
        ClipboardError::Refused(error)
    })
}

#[cfg(test)]
mod tests {
    use gtk4 as gtk;

    use super::*;
    use crate::ui::clipboard::ClipboardFormat;

    fn local_text(clipboard: &gdk::Clipboard) -> Option<String> {
        clipboard.content()?.value(String::static_type()).ok()?.get().ok()
    }

    #[gtk4::test]
    fn a_typed_copy_offers_its_type_and_plain_text() {
        let clipboard = gtk::Label::new(None).clipboard();
        let payload = ClipboardPayload {
            text: "a,b\n1,2\n".to_owned(),
            format: ClipboardFormat::Csv,
            rows: 1,
            skipped: 0,
        };

        write(&clipboard, &payload).expect("written");

        let formats = clipboard.formats();
        assert!(formats.contain_mime_type("text/csv"), "{}", formats.to_str());
        assert!(formats.contains_type(String::static_type()), "{}", formats.to_str());
        assert_eq!(local_text(&clipboard).as_deref(), Some("a,b\n1,2\n"));
    }

    #[gtk4::test]
    fn text_with_a_nul_is_refused_and_the_clipboard_kept() {
        let clipboard = gtk::Label::new(None).clipboard();
        clipboard.set_text("before");

        let error = write(&clipboard, &ClipboardPayload::plain("a\0b".to_owned())).expect_err("a NUL");

        assert!(matches!(error, ClipboardError::ContainsNul));
        assert_eq!(local_text(&clipboard).as_deref(), Some("before"));
    }
}
