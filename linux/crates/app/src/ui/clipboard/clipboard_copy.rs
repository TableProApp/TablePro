use std::cell::Cell;
use std::rc::Rc;
use std::sync::atomic::{AtomicU64, Ordering};

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gdk, glib};
use tablepro_core::export::{EncodeError, RenderInsertError};
use tablepro_session::runtime::Tasks;

use super::clipboard_writer::{holds_nul, write};
use super::{ClipboardError, ClipboardPayload, CopyError, CopyKind, CopyRequest, render_copy};
use crate::i18n::{gettext, gettext_f, ngettext_f};
use crate::ui::format::{format_thousands, plural_count};
use crate::ui::handler_guard::HandlerGuard;

/// The copy asked for last, in the whole process: every window copies
/// to the same display clipboard, and a large copy renders long enough
/// for a later, smaller one to land first.
static LATEST_COPY: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone, Copy)]
struct CopyTicket(u64);

impl CopyTicket {
    fn take() -> Self {
        Self(LATEST_COPY.fetch_add(1, Ordering::Relaxed) + 1)
    }

    fn is_latest(self) -> bool {
        LATEST_COPY.load(Ordering::Relaxed) == self.0
    }
}

/// Whether this process put something else on the clipboard since the
/// watch began: a copy that writes at once, or a text field's own Copy,
/// which no ticket sees. Another application's copy is not counted,
/// since Wayland announces the clipboard again on every focus change.
struct LocalWrite {
    seen: Rc<Cell<bool>>,
    _handler: HandlerGuard,
}

impl LocalWrite {
    fn watch(clipboard: &gdk::Clipboard) -> Self {
        let seen = Rc::new(Cell::new(false));
        let flag = seen.clone();
        let handler = clipboard.connect_changed(move |clipboard| {
            if clipboard.is_local() {
                flag.set(true);
            }
        });
        Self {
            seen,
            _handler: HandlerGuard::new(clipboard, handler),
        }
    }

    fn seen(&self) -> bool {
        self.seen.get()
    }
}

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
            CopyRequest::InClause { .. } => Self::InList,
            CopyRequest::Rows { .. } | CopyRequest::Insert(_) | CopyRequest::Values { .. } => Self::Rows,
        }
    }

    fn text(self, rows: usize) -> String {
        let n = rows as u64;
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
/// clipboard, then tell `report` how it went. Anything copied in this
/// process after this one wins, and this one then ends without a word.
/// The handle resolves once the copy has landed or given way.
pub(crate) fn copy_rows(
    widget: &impl IsA<gtk::Widget>,
    tasks: &Tasks,
    request: CopyRequest,
    report: impl Fn(&str) + 'static,
) -> glib::JoinHandle<()> {
    let ticket = CopyTicket::take();
    let clipboard = widget.as_ref().clipboard();
    let overtaken = LocalWrite::watch(&clipboard);
    let copied = Copied::of(&request);
    let rendering = render_copy(tasks, request);
    glib::spawn_future_local(async move {
        let rendered = rendering.await;
        if !ticket.is_latest() || overtaken.seen() {
            tracing::debug!("a copy finished after a later one and was dropped");
            return;
        }
        let payload = match rendered {
            Ok(Ok(payload)) => payload,
            Ok(Err(error)) => return report(&copy_error_text(&error)),
            Err(failure) => {
                tracing::warn!(%failure, "a copy could not be rendered");
                return report(&gettext("Couldn't copy the selection"));
            }
        };
        let (rows, skipped) = (payload.rows, payload.skipped);
        if let Err(error) = write(&clipboard, payload) {
            return report(&error.message());
        }
        report(&copied.text(rows));
        // NULL and binary values have no place in an IN list, so the
        // copy says how many it left out instead of handing back a
        // shorter list that quietly selects different rows.
        if skipped > 0 {
            report(&gettext_f(
                "{n} NULL or binary values left out of the IN clause",
                &[("n", &skipped.to_string())],
            ));
        }
    })
}

/// Put `text` on `widget`'s clipboard as it is, and tell `report`.
pub(crate) fn copy_text(widget: &impl IsA<gtk::Widget>, text: String, report: impl Fn(&str)) {
    copy_payload(widget, ClipboardPayload::plain(text), report);
}

/// Put a payload rendered already on `widget`'s clipboard, and tell
/// `report`.
pub(crate) fn copy_payload(widget: &impl IsA<gtk::Widget>, payload: ClipboardPayload, report: impl Fn(&str)) {
    if holds_nul(&payload.text) {
        return report(&ClipboardError::ContainsNul.message());
    }
    match write(&widget.as_ref().clipboard(), payload) {
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
        CopyError::Encode(EncodeError::NotXmlText { column }) => gettext_f(
            "Couldn't copy: the column “{column}” holds a control character",
            &[("column", column)],
        ),
        CopyError::Insert(RenderInsertError::Literal(_)) => {
            gettext("This row has a value that can't be written as SQL")
        }
        CopyError::Insert(RenderInsertError::NoValues) => gettext("This row has no value to put in an INSERT"),
        CopyError::Literal(_) => gettext("This column has a value that can't be written as SQL"),
        CopyError::EmptyInClause => gettext("Nothing to copy: an IN clause can't carry NULL or binary values"),
        CopyError::TextTableTooLarge => gettext("Too much to copy as a text table. Copy fewer rows or use CSV."),
        CopyError::ContainsNul => ClipboardError::ContainsNul.message(),
    }
}
