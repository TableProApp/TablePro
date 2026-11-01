use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::Value;
use tablepro_core::column::ResultColumn;
use tablepro_core::export::EncodeError;
use tablepro_session::runtime::Tasks;
use tablepro_storage::AppSettings;

use crate::services::grid::RowSnapshot;
use crate::ui::clipboard::{ClipboardFormat, ClipboardPayload};
use crate::ui::format::{format_thousands, plural_count};
use crate::ui::source_dialog::{SourceText, cut, more_bytes, source_dialog};

/// Longer text is cut in the dialog: the view lays out every character
/// it holds, and a value of megabytes would stall it.
const SHOWN_CHARS: usize = 10_000;
/// Binary shows as hex, two characters a byte.
const SHOWN_BYTES: usize = SHOWN_CHARS / 2;
/// Each item of an array is a line of its own.
const SHOWN_ITEMS: usize = 1_000;

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

fn render(request: RowJsonRequest) -> Result<RowJson, EncodeError> {
    let values = request.row.to_values();
    let full = tablepro_core::export::row_to_json(&request.columns, &values)?;
    let mut shortened = false;
    let shown_values: Vec<Value> = values.into_iter().map(|value| shown(value, &mut shortened)).collect();
    let shown = match shortened {
        true => tablepro_core::export::row_to_json(&request.columns, &shown_values)?,
        false => full.clone(),
    };
    Ok(RowJson { full, shown, shortened })
}

/// `value` as the dialog shows it, with anything long cut short and
/// saying how much is left out. A document cut short is no longer JSON,
/// so it shows as text.
fn shown(value: Value, shortened: &mut bool) -> Value {
    let cut = match &value {
        Value::Text(text) => shorten(text),
        Value::Json(json) => shorten(json.as_str()),
        Value::Other(other) => shorten(&other.text),
        Value::Bits(bits) => shorten(&bits.to_string()),
        Value::Decimal(decimal) => shorten(&decimal.to_string()),
        Value::Bytes(bytes) => shorten_bytes(bytes),
        _ => None,
    };
    if let Some(cut) = cut {
        *shortened = true;
        return Value::Text(cut);
    }
    let Value::Array(items) = value else {
        return value;
    };
    let more = items.len().saturating_sub(SHOWN_ITEMS) as u64;
    let mut kept: Vec<Value> = items
        .into_iter()
        .take(SHOWN_ITEMS)
        .map(|item| shown(item, shortened))
        .collect();
    if more > 0 {
        *shortened = true;
        kept.push(Value::Text(crate::i18n::ngettext_f(
            "… ({count} more item)",
            "… ({count} more items)",
            plural_count(more),
            &[("count", &format_thousands(more))],
        )));
    }
    Value::Array(kept)
}

fn shorten(text: &str) -> Option<String> {
    cut(text, SHOWN_CHARS)
}

/// The hex the grid writes for binary, cut after `SHOWN_BYTES` bytes.
fn shorten_bytes(bytes: &[u8]) -> Option<String> {
    let more = bytes.len().checked_sub(SHOWN_BYTES).filter(|more| *more > 0)?;
    let head = bytes.get(..SHOWN_BYTES)?;
    Some(format!(
        "0x{}{}",
        tablepro_core::hex::encode_lower(head),
        more_bytes(more as u64)
    ))
}

/// Render the row off the GTK thread, then show it over `parent`.
pub(crate) async fn present_row_json(
    parent: gtk::Widget,
    tasks: Tasks,
    settings: Option<Rc<AppSettings>>,
    request: RowJsonRequest,
) -> Option<adw::Dialog> {
    let dialog = match tasks.spawn_blocking_task(move || render(request)).await {
        Ok(Ok(rendered)) => row_json_dialog(rendered, settings.as_ref()),
        Ok(Err(refused)) => refused_alert(&refused).upcast(),
        Err(failure) => {
            tracing::warn!(%failure, "a row could not be rendered as JSON");
            return None;
        }
    };
    dialog.present(Some(&parent));
    Some(dialog)
}

/// Why the row has no JSON to show. Both refusals name the column the
/// grid shows as unreadable.
fn refused_alert(refused: &EncodeError) -> adw::AlertDialog {
    let (EncodeError::Undecodable { column } | EncodeError::NotXmlText { column }) = refused;
    let alert = adw::AlertDialog::new(
        Some(&crate::i18n::gettext("Can't Show Row as JSON")),
        Some(&crate::i18n::gettext_f(
            "The column “{column}” holds a value TablePro couldn't read, so the row has no JSON to show.",
            &[("column", column)],
        )),
    );
    alert.add_response("close", &crate::i18n::gettext("_Close"));
    alert
}

fn row_json_dialog(json: RowJson, settings: Option<&Rc<AppSettings>>) -> adw::Dialog {
    let RowJson { full, shown, shortened } = json;
    let text = SourceText {
        title: crate::i18n::gettext("Row as JSON"),
        language: "json",
        label: crate::i18n::gettext("Row as JSON"),
        shown,
        copied: ClipboardPayload {
            text: full,
            format: ClipboardFormat::Json,
            rows: 1,
            skipped: 0,
            cells: None,
        },
        cut_note: shortened.then(|| crate::i18n::gettext("Long values are shortened here. Copy includes them in full.")),
        size: (560, 480),
    };
    source_dialog(text, settings).dialog
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tablepro_core::column::ColumnType;

    use super::*;
    use crate::test_support::{
        OwnedWindow, after_next_frame, descendants, finish_on_main, first_descendant_of_type, wait_until,
    };

    fn local_text(clipboard: &gtk::gdk::Clipboard) -> Option<String> {
        clipboard.content()?.value(String::static_type()).ok()?.get().ok()
    }

    #[gtk4::test]
    fn row_json_dialog_caps_display_but_copies_full_value() {
        adw::init().expect("libadwaita initialises under the test backend");
        let window = OwnedWindow::presented(adw::Window::new());
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
            present_row_json(window.clone().upcast(), runtime.tasks(), None, request),
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

    #[test]
    fn every_kind_of_long_value_is_cut_for_display_and_kept_for_copy() {
        const LONG: usize = 50_000;
        let column = |name: &str, kind: &str| ResultColumn::new(name, ColumnType::untyped_text(kind));
        let document = format!("[{}]", vec!["1"; LONG].join(","));
        let shape = "x".repeat(LONG);
        let request = RowJsonRequest {
            columns: vec![
                column("doc", "jsonb"),
                column("blob", "bytea"),
                column("shape", "geometry"),
                column("tags", "text[]"),
            ]
            .into(),
            row: RowSnapshot::new(
                vec![
                    Value::Json(tablepro_core::value::JsonText::parse(document.clone()).expect("JSON")),
                    Value::Bytes(vec![0xab; LONG]),
                    Value::Other(Box::new(tablepro_core::value::OtherValue {
                        type_name: "geometry".to_owned(),
                        text: shape.clone(),
                    })),
                    Value::Array(vec![Value::Text("t".to_owned()); LONG]),
                ]
                .into(),
                Vec::new(),
            ),
        };

        let rendered = render(request).expect("a readable row");

        assert!(rendered.shortened);
        let longest = rendered.shown.lines().map(str::len).max().unwrap_or_default();
        assert!(longest < SHOWN_CHARS + 100, "a line of {longest} bytes is laid out");
        assert!(rendered.shown.len() < 100_000, "{} bytes shown", rendered.shown.len());
        assert!(
            rendered.shown.contains("… (45,000 more bytes)"),
            "the binary does not say what is left"
        );
        assert!(
            rendered.shown.contains("… (49,000 more items)"),
            "the array does not say what is left"
        );
        let full: serde_json::Value = serde_json::from_str(&rendered.full).expect("the copy is JSON");
        assert_eq!(full["doc"].as_array().map(Vec::len), Some(LONG));
        assert_eq!(full["blob"].as_str().map(str::len), Some(2 + 2 * LONG));
        assert_eq!(full["shape"], serde_json::json!(shape));
        assert_eq!(full["tags"].as_array().map(Vec::len), Some(LONG));
    }

    #[gtk4::test]
    fn an_unreadable_value_is_refused_by_name_rather_than_shown_as_null() {
        adw::init().expect("libadwaita initialises under the test backend");
        let window = OwnedWindow::presented(adw::Window::new());
        let runtime = crate::test_support::test_runtime();
        let unreadable = Value::Undecodable(Box::new(tablepro_core::value::UndecodedValue {
            type_name: "text".to_owned(),
            reason: tablepro_core::value::UndecodableReason::InvalidEncoding,
        }));
        let request = RowJsonRequest {
            columns: vec![
                ResultColumn::new("id", ColumnType::untyped_text("text")),
                ResultColumn::new("body", ColumnType::untyped_text("text")),
            ]
            .into(),
            row: RowSnapshot::new(vec![Value::Int(1), unreadable].into(), Vec::new()),
        };

        let dialog = finish_on_main(
            Duration::from_secs(10),
            present_row_json(window.clone().upcast(), runtime.tasks(), None, request),
        )
        .expect("the render to end")
        .expect("a dialog");

        let alert = dialog
            .downcast::<adw::AlertDialog>()
            .expect("an alert, not the JSON view");
        assert_eq!(
            alert.body().as_str(),
            "The column “body” holds a value TablePro couldn't read, so the row has no JSON to show."
        );
        alert.force_close();
        runtime.shutdown();
    }

    #[gtk4::test]
    fn a_closed_dialog_lets_go_of_the_row() {
        adw::init().expect("libadwaita initialises under the test backend");
        let window = OwnedWindow::presented(adw::Window::new());
        let dialog = row_json_dialog(
            RowJson {
                full: r#"{"id": 1}"#.to_owned(),
                shown: r#"{"id": 1}"#.to_owned(),
                shortened: false,
            },
            None,
        );
        dialog.present(Some(&*window));
        let view = first_descendant_of_type::<sourceview5::View>(&dialog).expect("the text");
        wait_until(Duration::from_secs(10), || view.is_mapped()).expect("the dialog on screen");
        after_next_frame(&view);
        let row = view.buffer().downgrade();

        drop(view);
        dialog.force_close();
        drop(dialog);

        wait_until(Duration::from_secs(10), || row.upgrade().is_none()).expect("the row's text outlived its dialog");
    }
}
