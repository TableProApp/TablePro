use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use tablepro_core::export::{EncodeError, RenderInsertError};
use tablepro_session::runtime::Tasks;

use super::{ClipboardPayload, CopyError, CopyKind, CopyRequest, render_copy, write};
use crate::i18n::{gettext, gettext_f, ngettext_f};
use crate::ui::count_text::{format_thousands, plural_count};

/// What the toast after a copy counts.
#[derive(Debug, Clone, Copy)]
enum Copied {
    Value,
    Rows,
    InList,
}

impl Copied {
    fn of(request: &CopyRequest) -> Self {
        match request {
            CopyRequest::Rows {
                kind: CopyKind::Value(_),
                ..
            } => Self::Value,
            CopyRequest::Rows {
                kind: CopyKind::InClause(_),
                ..
            } => Self::InList,
            CopyRequest::Rows { .. } | CopyRequest::Insert(_) => Self::Rows,
        }
    }

    fn text(self, payload: &ClipboardPayload) -> String {
        let n = payload.rows as u64;
        match self {
            Self::Value => gettext("Copied to clipboard"),
            Self::Rows => ngettext_f(
                "Copied {n} row",
                "Copied {n} rows",
                plural_count(n),
                &[("n", &format_thousands(n))],
            ),
            Self::InList => ngettext_f(
                "Copied {n} value",
                "Copied {n} values",
                plural_count(n),
                &[("n", &format_thousands(n))],
            ),
        }
    }
}

/// Render `request` off the GTK thread and put it on `widget`'s
/// clipboard, then tell `report` how it went.
pub(crate) fn copy_rows(
    widget: &impl IsA<gtk::Widget>,
    tasks: &Tasks,
    request: CopyRequest,
    report: impl Fn(&str) + 'static,
) {
    let clipboard = widget.as_ref().clipboard();
    let copied = Copied::of(&request);
    let rendering = render_copy(tasks, request);
    glib::spawn_future_local(async move {
        let payload = match rendering.await {
            Ok(Ok(payload)) => payload,
            Ok(Err(error)) => return report(&copy_error_text(&error)),
            Err(failure) => {
                tracing::warn!(%failure, "a copy could not be rendered");
                return report(&gettext("Couldn't copy the selection"));
            }
        };
        if let Err(error) = write(&clipboard, &payload) {
            return report(&error.message());
        }
        report(&copied.text(&payload));
        // NULL and binary values have no place in an IN list, so the
        // copy says how many it left out instead of handing back a
        // shorter list that quietly selects different rows.
        if payload.skipped > 0 {
            report(&gettext_f(
                "{n} NULL or binary values left out of the IN clause",
                &[("n", &payload.skipped.to_string())],
            ));
        }
    });
}

/// Put `text` on `widget`'s clipboard as it is, and tell `report`.
pub(crate) fn copy_text(widget: &impl IsA<gtk::Widget>, text: String, report: impl Fn(&str)) {
    match write(&widget.as_ref().clipboard(), &ClipboardPayload::plain(text)) {
        Ok(()) => report(&gettext("Copied to clipboard")),
        Err(error) => report(&error.message()),
    }
}

fn copy_error_text(error: &CopyError) -> String {
    match error {
        CopyError::Encode(EncodeError::Undecodable { column }) => gettext_f(
            "Couldn't copy: the column “{column}” holds a value TablePro couldn't read",
            &[("column", column)],
        ),
        CopyError::Insert(RenderInsertError::Literal(_)) => {
            gettext("This row has a value that can't be written as SQL")
        }
        CopyError::Insert(RenderInsertError::NoValues) => gettext("This row has no value to put in an INSERT"),
        CopyError::EmptyInClause => gettext("Nothing to copy: an IN clause can't carry NULL or binary values"),
    }
}
