use std::rc::{Rc, Weak};

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, gdk, glib};
use libadwaita as adw;
use sourceview5::prelude::*;
use tablepro_core::Value;
use tablepro_core::column::ColumnKind;
use tablepro_core::edit::{CellInput, EditParseError, EditText, edit_text};

use super::RowDetailPane;
use crate::application::component_matches;
use crate::i18n::{gettext, gettext_f};
use crate::services::grid::{
    CellLock, CommitResult, EDIT_MAX_BYTES, EditStart, GridColumn, GridRowId, auto_filled_sentinel, display_text,
    empty_placeholder, hex_dump,
};
use crate::ui::data_grid::selection::Target;
use crate::ui::data_grid::{DataGrid, GridRow, PinnedRow};
use crate::ui::error_text::edit_parse_message;
use crate::ui::handler_guard::HandlerGuard;

/// The scheme a grid without settings paints with, as the multi-line
/// editor did. The resolver follows it to its dark variant.
const FALLBACK_SCHEME: &str = "Adwaita";

/// The value editor's own key handler, named so it can be told from the
/// view's.
pub const KEYS_NAME: &str = "tablepro-row-detail-value-keys";

/// An edit open in the value editor. It commits to the row it began on,
/// measured against the value it began with.
#[derive(Debug)]
pub struct OpenEdit {
    row: PinnedRow,
    column: usize,
    start: EditStart,
}

/// What the value editor was last filled from.
#[derive(Debug, PartialEq)]
pub struct Loaded {
    row: GridRow,
    generation: u64,
    revision: u32,
    column: usize,
}

/// What the placeholder over an empty value editor says.
#[derive(Debug, Default)]
pub struct Placeholders {
    /// For the value as it opened.
    open: Option<String>,
    /// What an emptied value commits.
    emptied: Option<String>,
    /// Emptied text that opened empty commits nothing, so it still holds
    /// what it opened with.
    opened_empty: bool,
}

/// How a commit takes a value the column refuses.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Commit {
    /// Focus-out, Ctrl+Return or a picked date: the text stays, marked,
    /// with the reason under it.
    Keep,
    /// A row change, a reload, a save or a close: the text goes.
    Teardown,
}

/// What the value editor shows for one cell.
#[derive(Debug, Clone, PartialEq)]
pub struct ValueContent {
    pub text: String,
    /// Why the value cannot be typed over, `None` when it can.
    pub message: Option<String>,
    pub open_placeholder: Option<String>,
    pub emptied_placeholder: Option<String>,
    pub language: Option<&'static str>,
    pub calendar: bool,
    /// A hex dump lines up only unwrapped.
    pub hex_dump: bool,
}

pub fn value_content(column: &GridColumn, row: &GridRowId, lock: Option<CellLock>, input: &CellInput) -> ValueContent {
    let kind = &column.value_type().kind;
    let (text, refusal) = match input {
        CellInput::Value(value) => typed_form(column, value),
        CellInput::Default => (String::new(), None),
    };
    let message = lock.map(|lock| lock.explanation(edit_parse_message)).or(refusal);
    let editable = message.is_none();
    let emptied_placeholder = editable.then(|| empty_placeholder(column, row)).flatten();
    let open_placeholder = match input {
        CellInput::Value(Value::Null) => Some("NULL".to_owned()),
        CellInput::Default if column.auto_filled() => Some(auto_filled_sentinel()),
        CellInput::Default => Some("DEFAULT".to_owned()),
        // An empty dump would read as no value at all.
        CellInput::Value(value @ Value::Bytes(bytes)) if bytes.is_empty() => Some(
            display_text(value, &column.column_type, &mut String::new())
                .text
                .to_owned(),
        ),
        CellInput::Value(_) => emptied_placeholder.clone(),
    };
    ValueContent {
        text,
        open_placeholder,
        emptied_placeholder,
        language: match kind {
            ColumnKind::Json { .. } => Some("json"),
            ColumnKind::Xml => Some("xml"),
            _ => None,
        },
        calendar: editable && matches!(kind, ColumnKind::Date | ColumnKind::Timestamp { .. }),
        hex_dump: matches!(input, CellInput::Value(Value::Bytes(_))),
        message,
    }
}

/// The whole value to type over, or the text the grid draws for it and
/// why it cannot be typed over.
fn typed_form(column: &GridColumn, value: &Value) -> (String, Option<String>) {
    let refusal = match edit_text(value, column.value_type()) {
        // A text buffer holds the text only up to a NUL, and committing
        // it would cut the value there.
        EditText::Editable(text) if text.contains('\0') => gettext("Values with a NUL character can't be edited here"),
        // Laid out whole on the GTK thread, it would stall the window.
        EditText::Editable(text) if text.len() > EDIT_MAX_BYTES => too_large_to_edit(),
        EditText::Editable(text) => return (text, None),
        EditText::ReadOnly(reason) => edit_parse_message(&EditParseError::NotEditable(reason)),
    };
    let text = match value {
        Value::Null => String::new(),
        Value::Bytes(bytes) => hex_dump(bytes),
        value => {
            let mut scratch = String::new();
            display_text(value, &column.column_type, &mut scratch).text.to_owned()
        }
    };
    (text, Some(refusal))
}

fn too_large_to_edit() -> String {
    let size = glib::format_size(EDIT_MAX_BYTES as u64);
    gettext_f("Values over {size} can't be edited here", &[("size", size.as_str())])
}

fn set_class(widget: &impl IsA<gtk::Widget>, class: &str, on: bool) {
    match on {
        true => widget.as_ref().add_css_class(class),
        false => widget.as_ref().remove_css_class(class),
    }
}

impl RowDetailPane {
    pub(super) fn connect_value_editor(&self, grid: &DataGrid) {
        let imp = self.imp();
        imp.value_buffer.connect_changed(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move |_| pane.text_changed()
        ));
        let view = imp.value_view.get();
        view.add_controller(self.edit_keys());
        view.add_controller(self.edit_focus());
        view.connect_preedit_changed(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move |_, preedit| pane.preedit_changed(preedit)
        ));
        self.follow_style_scheme(grid);
    }

    /// Capture phase, so Escape restores before the view takes it and
    /// Ctrl+Return saves before the view adds a line. While a preedit is
    /// open both keys are the input method's.
    fn edit_keys(&self) -> gtk::EventControllerKey {
        let keys = gtk::EventControllerKey::new();
        keys.set_name(Some(KEYS_NAME));
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        let weak = self.downgrade();
        keys.connect_key_pressed(move |_, keyval, _, state| match weak.upgrade() {
            Some(pane) => pane.edit_key(keyval, state),
            None => glib::Propagation::Proceed,
        });
        keys
    }

    fn edit_key(&self, keyval: gdk::Key, state: gdk::ModifierType) -> glib::Propagation {
        if self.imp().composing.get() {
            return glib::Propagation::Proceed;
        }
        if component_matches("cell-editor.save-text", keyval, state) {
            self.commit(Commit::Keep);
            return glib::Propagation::Stop;
        }
        if component_matches("cell-editor.cancel", keyval, state) && self.is_editing_value() {
            self.cancel_edit();
            return glib::Propagation::Stop;
        }
        glib::Propagation::Proceed
    }

    fn edit_focus(&self) -> gtk::EventControllerFocus {
        let focus = gtk::EventControllerFocus::new();
        let weak = self.downgrade();
        focus.connect_leave(move |focus| {
            let Some(pane) = weak.upgrade() else {
                return;
            };
            // Another window taking the focus leaves it in the view, so
            // the edit stays open for when the window is back. A focus
            // moving within the window is unset while the leave runs.
            if focus.widget().is_some_and(|view| crate::ui::a11y::holds_focus(&view)) {
                return;
            }
            // Focus moving to an input method's popup ends the edit mid
            // composition, so the commit waits for the preedit to clear.
            if pane.imp().composing.get() {
                pane.imp().commit_when_composed.set(true);
                return;
            }
            pane.commit(Commit::Keep);
        });
        focus
    }

    fn preedit_changed(&self, preedit: &str) {
        let imp = self.imp();
        imp.composing.set(!preedit.is_empty());
        if preedit.is_empty() && imp.commit_when_composed.replace(false) {
            self.commit(Commit::Keep);
        }
    }

    fn is_editing_value(&self) -> bool {
        self.imp().edit.borrow().is_some()
    }

    fn text_changed(&self) {
        self.update_placeholder();
        if !self.imp().loading.get() {
            self.begin_edit();
        }
    }

    /// The user typed: the edit is pinned to the row and the value as
    /// they were when it began.
    fn begin_edit(&self) {
        if self.is_editing_value() {
            return;
        }
        let (Some(grid), Some(pin), Some(column)) = (self.grid(), self.current_pin(), self.imp().field.get()) else {
            return;
        };
        let Some(row) = pin.get() else {
            return;
        };
        let start = edit_start(&grid, row, column);
        self.imp().edit.replace(Some(OpenEdit {
            row: pin.clone(),
            column,
            start,
        }));
        grid.set_editing(true);
    }

    pub(super) fn commit(&self, how: Commit) {
        let imp = self.imp();
        imp.commit_when_composed.set(false);
        // Out of the pane first: the commit redraws the row, which reaches
        // the pane again, and a reload commits through it.
        let Some(edit) = imp.edit.take() else {
            return;
        };
        let Some(grid) = self.grid() else {
            return;
        };
        let typed = self.typed_text();
        let result = grid.edit().commit_value(&edit.row, edit.column, &edit.start, &typed);
        if let (Some(CommitResult::Rejected(error)), Commit::Keep) = (&result, how) {
            self.show_message(Some(&edit_parse_message(error)), true);
            imp.edit.replace(Some(edit));
            return;
        }
        self.end_edit(&grid);
    }

    pub(super) fn cancel_edit(&self) {
        if self.imp().edit.take().is_none() {
            return;
        }
        self.imp().commit_when_composed.set(false);
        if let Some(grid) = self.grid() {
            self.end_edit(&grid);
        }
    }

    fn end_edit(&self, grid: &DataGrid) {
        self.imp().loaded.take();
        grid.set_editing(false);
        self.render();
    }

    pub(super) fn typed_text(&self) -> String {
        let buffer = self.imp().value_buffer.get();
        buffer.text(&buffer.start_iter(), &buffer.end_iter(), true).to_string()
    }

    pub(super) fn field_column(&self) -> Option<GridColumn> {
        let grid = self.grid()?;
        grid.grid_columns().get(self.imp().field.get()?).cloned()
    }

    /// Fill the value editor from the shown row's selected field, unless
    /// the user is typing in it or it holds that value already.
    pub(super) fn load_value(&self) {
        let imp = self.imp();
        if !self.is_open() || self.is_editing_value() {
            return;
        }
        let (Some(grid), Some(row), Some(column)) = (self.grid(), self.current_row(), self.field_column()) else {
            self.show_no_value();
            return;
        };
        let loaded = Loaded {
            row: row.clone(),
            generation: row.generation(),
            revision: row.revision(),
            column: column.index,
        };
        if imp.loaded.borrow().as_ref() == Some(&loaded) {
            return;
        }
        let tracked = grid.tracked();
        let input = tracked.edit_input(&row, column.index);
        let content = value_content(&column, &row.id(), tracked.lock(&column, &row), &input);
        self.show_value(&column.name, &content);
        self.show_picture(match input {
            CellInput::Value(Value::Bytes(bytes)) => Some(bytes),
            _ => None,
        });
        imp.loaded.replace(Some(loaded));
    }

    fn show_no_value(&self) {
        let content = ValueContent {
            text: String::new(),
            message: None,
            open_placeholder: None,
            emptied_placeholder: None,
            language: None,
            calendar: false,
            hex_dump: false,
        };
        self.show_value("", &content);
        self.show_picture(None);
        self.imp().value_view.set_editable(false);
        self.imp().loaded.take();
    }

    fn show_value(&self, name: &str, content: &ValueContent) {
        let imp = self.imp();
        imp.placeholders.replace(Placeholders {
            open: content.open_placeholder.clone(),
            emptied: content.emptied_placeholder.clone(),
            opened_empty: content.text.is_empty(),
        });
        let buffer = imp.value_buffer.get();
        let language = content
            .language
            .and_then(|id| sourceview5::LanguageManager::default().language(id));
        buffer.set_language(language.as_ref());
        imp.loading.set(true);
        // So the view's undo cannot step back into another field's value.
        buffer.begin_irreversible_action();
        buffer.set_text(&content.text);
        buffer.end_irreversible_action();
        imp.loading.set(false);
        buffer.place_cursor(&buffer.start_iter());
        let view = imp.value_view.get();
        view.set_editable(content.message.is_none());
        imp.field_label.set_label(name);
        // Through the widget: sourceview5 maps GtkAccessible only from
        // GTK 4.10, a feature the app does not turn on.
        view.upcast_ref::<gtk::Widget>()
            .update_property(&[gtk::accessible::Property::Label(name)]);
        self.show_message(content.message.as_deref(), false);
        imp.calendar_button.set_visible(content.calendar);
        let (wrap, hscroll) = match content.hex_dump {
            true => (gtk::WrapMode::None, gtk::PolicyType::Automatic),
            false => (gtk::WrapMode::WordChar, gtk::PolicyType::Never),
        };
        view.set_wrap_mode(wrap);
        imp.value_scroller.set_hscrollbar_policy(hscroll);
        self.update_placeholder();
    }

    fn update_placeholder(&self) {
        let imp = self.imp();
        let text = match imp.value_buffer.char_count() {
            0 => {
                let placeholders = imp.placeholders.borrow();
                match placeholders.opened_empty {
                    true => placeholders.open.clone(),
                    false => placeholders.emptied.clone(),
                }
            }
            _ => None,
        };
        imp.placeholder_label.set_label(text.as_deref().unwrap_or_default());
        imp.placeholder_label.set_visible(text.is_some());
    }

    /// The sentence under the editor: why the cell is locked, dimmed, or
    /// why the column refused what was typed, as an error.
    fn show_message(&self, message: Option<&str>, refused: bool) {
        let imp = self.imp();
        let label = imp.message_label.get();
        label.set_label(message.unwrap_or_default());
        label.set_visible(message.is_some());
        set_class(&label, "error", refused);
        set_class(&label, "dimmed", !refused);
        let view = imp.value_view.get();
        set_class(&view, "error", refused);
        crate::ui::a11y::show_invalid(&view, message.filter(|_| refused));
        if let (false, Some(message)) = (refused, message) {
            view.upcast_ref::<gtk::Widget>()
                .update_property(&[gtk::accessible::Property::Description(message)]);
        }
    }

    /// The menu's items are the grid's own cell actions, held on the
    /// shown row and field until it closes, as the cell menu holds its
    /// cell, so they act on the field while the grid has no focus.
    pub(super) fn connect_value_menu(&self, grid: &DataGrid) {
        let button = self.imp().value_menu_button.get();
        button.set_create_popup_func(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move |_| pane.arm_value_menu()
        ));
        if let Some(popover) = button.popover() {
            popover.connect_closed(glib::clone!(
                #[weak]
                grid,
                move |_| grid.release_menu_target_soon()
            ));
        }
    }

    fn arm_value_menu(&self) {
        let Some(grid) = self.grid() else {
            return;
        };
        let cell = self.current_pin().zip(self.imp().field.get());
        let rows = cell.iter().map(|(row, _)| row.clone()).collect();
        grid.hold_menu_target(Target { cell, rows });
        grid.refresh_actions();
    }

    /// The SQL editor's scheme where the grid has the settings, in the
    /// variant for the current style, following a switch of either.
    fn follow_style_scheme(&self, grid: &DataGrid) {
        let settings = grid.config().map(|config| config.settings.clone());
        let paint = {
            let buffer = self.imp().value_buffer.get().downgrade();
            let settings = settings.as_ref().map(Rc::downgrade);
            Rc::new(move || {
                let Some(buffer) = buffer.upgrade() else {
                    return;
                };
                let preferred = settings
                    .as_ref()
                    .and_then(Weak::upgrade)
                    .map_or_else(|| FALLBACK_SCHEME.to_owned(), |settings| settings.style_scheme());
                buffer.set_style_scheme(crate::ui::style_scheme_resolver::scheme(&preferred).as_ref());
            })
        };
        paint();
        let style_manager = adw::StyleManager::default();
        let on_dark = {
            let paint = paint.clone();
            style_manager.connect_dark_notify(move |_| paint())
        };
        let mut guards = vec![HandlerGuard::new(&style_manager, on_dark)];
        if let Some(settings) = settings {
            let on_scheme = settings
                .gio()
                .connect_changed(Some(tablepro_storage::settings::keys::STYLE_SCHEME), move |_, _| {
                    paint()
                });
            guards.push(HandlerGuard::new(settings.gio(), on_scheme));
        }
        self.imp().guards.borrow_mut().extend(guards);
    }
}

/// An edit of `row`'s `column` as it stands now: the value the page
/// read, which a save is checked against, and the value with any
/// pending edit, which the editor shows.
fn edit_start(grid: &DataGrid, row: &GridRow, column: usize) -> EditStart {
    EditStart {
        row: row.id(),
        read: row
            .cells()
            .and_then(|cells| cells.get(column).cloned())
            .unwrap_or(Value::Null),
        original: grid.tracked().edit_input(row, column),
    }
}
