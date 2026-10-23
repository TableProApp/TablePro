use gtk4::prelude::*;
use gtk4::{gdk, glib};
use thiserror::Error;

use super::{CELLS_MIME_TYPE, ClipboardPayload};

#[derive(Debug, Error)]
pub(crate) enum ClipboardError {
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

/// The text type is a C string, so a NUL would cut the copy short, and
/// a cut copy pasted back would change the value without a word.
pub(super) fn holds_nul(text: &str) -> bool {
    text.contains('\0')
}

/// Put `payload` on the clipboard as its own type, as the cells it
/// holds and as plain text, so an application that knows a type takes
/// it, and any other gets the text. The caller has already refused text
/// that `holds_nul`.
pub(super) fn write(clipboard: &gdk::Clipboard, payload: ClipboardPayload) -> Result<(), ClipboardError> {
    let mime_type = payload.format.mime_type();
    if mime_type.is_none() && payload.cells.is_none() {
        clipboard.set_text(&payload.text);
        return Ok(());
    }
    let mut providers = Vec::with_capacity(3);
    if let Some(cells) = payload.cells {
        providers.push(gdk::ContentProvider::for_bytes(
            CELLS_MIME_TYPE,
            &glib::Bytes::from_owned(cells.into_bytes()),
        ));
    }
    let text = payload.text.to_value();
    if let Some(mime_type) = mime_type {
        providers.push(gdk::ContentProvider::for_bytes(
            mime_type,
            &glib::Bytes::from_owned(payload.text.into_bytes()),
        ));
    }
    providers.push(gdk::ContentProvider::for_value(&text));
    let provider = gdk::ContentProvider::new_union(&providers);
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
            cells: None,
        };

        write(&clipboard, payload).expect("written");

        let formats = clipboard.formats();
        assert!(formats.contain_mime_type("text/csv"), "{}", formats.to_str());
        assert!(formats.contains_type(String::static_type()), "{}", formats.to_str());
        assert_eq!(local_text(&clipboard).as_deref(), Some("a,b\n1,2\n"));
    }
}
