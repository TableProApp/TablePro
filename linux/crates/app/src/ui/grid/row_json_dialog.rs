use std::sync::Arc;

use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use sourceview5::prelude::*;
use tablepro_core::Value;
use tablepro_core::column::ResultColumn;
use tablepro_session::runtime::Tasks;

use super::RowSnapshot;
use crate::ui::clipboard::{ClipboardFormat, ClipboardPayload};
use crate::ui::format::{format_thousands, plural_count};

/// Longer text is cut in the dialog: the view lays out every character
/// it holds, and a value of megabytes would stall it.
const SHOWN_CHARS: usize = 10_000;

/// One row to show as JSON, under the grid's visible columns.
#[derive(Debug)]
pub struct RowJsonRequest {
    pub columns: Arc<[ResultColumn]>,
    pub row: RowSnapshot,
}

/// The row's JSON in full, for a copy, and as the dialog shows it.
struct RowJson {
    full: String,
    shown: String,
    shortened: bool,
}

fn render(request: RowJsonRequest) -> RowJson {
    let values = request.row.to_values();
    let full = tablepro_core::export::row_to_json(&request.columns, &values);
    let mut shortened = false;
    let shown_values: Vec<Value> = values
        .into_iter()
        .map(|value| match value {
            Value::Text(text) => match shorten(&text) {
                Some(cut) => {
                    shortened = true;
                    Value::Text(cut)
                }
                None => Value::Text(text),
            },
            other => other,
        })
        .collect();
    let shown = match shortened {
        true => tablepro_core::export::row_to_json(&request.columns, &shown_values),
        false => full.clone(),
    };
    RowJson { full, shown, shortened }
}

/// `text` cut at a character boundary after `SHOWN_CHARS` characters,
/// saying how much is left out, or `None` when it fits.
fn shorten(text: &str) -> Option<String> {
    let (end, _) = text.char_indices().nth(SHOWN_CHARS)?;
    let more = (text.len() - end) as u64;
    Some(format!(
        "{}{}",
        &text[..end],
        crate::i18n::ngettext_f(
            "… ({count} more byte)",
            "… ({count} more bytes)",
            plural_count(more),
            &[("count", &format_thousands(more))],
        )
    ))
}

/// Render the row off the GTK thread, then show it over `parent`.
pub(crate) async fn present_row_json(
    parent: gtk::Widget,
    tasks: Tasks,
    request: RowJsonRequest,
) -> Option<adw::Dialog> {
    let rendered = match tasks.spawn_blocking_task(move || render(request)).await {
        Ok(rendered) => rendered,
        Err(failure) => {
            tracing::warn!(%failure, "a row could not be rendered as JSON");
            return None;
        }
    };
    let dialog = row_json_dialog(rendered);
    dialog.present(Some(&parent));
    Some(dialog)
}

fn row_json_dialog(json: RowJson) -> adw::Dialog {
    let RowJson { full, shown, shortened } = json;
    let buffer = sourceview5::Buffer::new(None);
    if let Some(lang) = sourceview5::LanguageManager::default().language("json") {
        buffer.set_language(Some(&lang));
    }
    let scheme_name = if adw::StyleManager::default().is_dark() {
        "Adwaita-dark"
    } else {
        "Adwaita"
    };
    buffer.set_style_scheme(sourceview5::StyleSchemeManager::default().scheme(scheme_name).as_ref());
    buffer.set_text(&shown);
    let view = sourceview5::View::with_buffer(&buffer);
    view.set_editable(false);
    view.set_monospace(true);
    view.set_show_line_numbers(true);
    view.set_top_margin(8);
    view.set_left_margin(8);
    let scrolled = gtk::ScrolledWindow::builder().child(&view).vexpand(true).build();

    let copy_button = gtk::Button::from_icon_name(crate::ui::icons::EDIT_COPY);
    crate::ui::a11y::describe_icon_button(&copy_button, &crate::i18n::gettext("Copy"), None);
    let payload = ClipboardPayload {
        text: full,
        format: ClipboardFormat::Json,
        rows: 1,
        skipped: 0,
    };
    let toasts = adw::ToastOverlay::new();
    toasts.set_child(Some(&scrolled));
    let shown_on = toasts.downgrade();
    copy_button.connect_clicked(move |button| {
        let shown_on = shown_on.clone();
        crate::ui::clipboard::copy_payload(button, payload.clone(), move |message| {
            if let Some(toasts) = shown_on.upgrade() {
                toasts.add_toast(crate::ui::plain_toast(message));
            }
        });
    });
    let header = adw::HeaderBar::new();
    header.pack_end(&copy_button);
    let banner = adw::Banner::new(&crate::i18n::gettext(
        "Long values are shortened here. Copy includes them in full.",
    ));
    banner.set_revealed(shortened);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.add_top_bar(&banner);
    toolbar.set_content(Some(&toasts));

    adw::Dialog::builder()
        .title(crate::i18n::gettext("Row as JSON"))
        .content_width(560)
        .content_height(480)
        .child(&toolbar)
        .build()
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tablepro_core::column::ColumnType;

    use super::*;
    use crate::test_support::{descendants, finish_on_main, first_descendant_of_type};

    fn local_text(clipboard: &gtk::gdk::Clipboard) -> Option<String> {
        clipboard.content()?.value(String::static_type()).ok()?.get().ok()
    }

    #[gtk4::test]
    fn row_json_dialog_caps_display_but_copies_full_value() {
        adw::init().expect("libadwaita initialises under the test backend");
        let window = adw::Window::new();
        window.present();
        let runtime = crate::test_support::test_runtime();
        let long = "x".repeat(25_000);
        let request = RowJsonRequest {
            columns: vec![
                ResultColumn::new("id", ColumnType::untyped_text("text")),
                ResultColumn::new("body", ColumnType::untyped_text("text")),
            ]
            .into(),
            row: RowSnapshot::new(vec![Value::Int(1), Value::Text(long.clone())].into(), Vec::new()),
        };

        let dialog = finish_on_main(
            Duration::from_secs(10),
            present_row_json(window.clone().upcast(), runtime.tasks(), request),
        )
        .expect("the render to end")
        .expect("the dialog");

        let view = first_descendant_of_type::<sourceview5::View>(&dialog).expect("the text");
        let buffer = view.buffer();
        let shown = buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string();
        assert!(!shown.contains(&long), "the whole value was laid out");
        assert!(
            shown.contains("… (15,000 more bytes)"),
            "{}",
            &shown[shown.len() - 60..]
        );
        let banner = first_descendant_of_type::<adw::Banner>(&dialog).expect("the banner");
        assert!(banner.is_revealed());

        let copy = descendants(&dialog)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
            .find(|button| button.tooltip_text().as_deref() == Some("Copy"))
            .expect("the copy button");
        copy.emit_clicked();

        assert!(
            descendants(&dialog)
                .iter()
                .filter_map(|widget| widget.downcast_ref::<gtk::Label>())
                .any(|label| label.label() == "Copied to clipboard"),
            "no toast said the copy landed"
        );
        let clipboard = copy.clipboard();
        assert!(clipboard.formats().contain_mime_type("application/json"));
        let copied = local_text(&clipboard).expect("the copied text");
        assert!(copied.contains(&long), "the copy was shortened too");
        let parsed: serde_json::Value = serde_json::from_str(&copied).expect("the copy is JSON");
        assert_eq!(parsed["body"], serde_json::json!(long));
        dialog.close();
        runtime.shutdown();
    }
}
