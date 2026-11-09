use std::cell::{Cell, RefCell};
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use sourceview5::prelude::*;
use tablepro_core::export::EncodeError;
use tablepro_session::runtime::Tasks;

use crate::i18n::{gettext, gettext_f, ngettext_f};
use crate::ui::clipboard::{ClipboardFormat, ClipboardPayload, copy_payload};
use crate::ui::data_grid::{DataGrid, JsonPreview, JsonPreviewRequest, json_preview};
use crate::ui::handler_guard::HandlerGuard;
use crate::ui::tab_load::{ContentPage, LoadPresentation, StaleBanner};

pub(super) struct JsonView {
    state: Rc<State>,
}

struct State {
    root: adw::ToolbarView,
    stack: gtk::Stack,
    view: sourceview5::View,
    error: adw::StatusPage,
    stale: StaleBanner,
    notice: adw::Banner,
    toasts: adw::ToastOverlay,
    copy: gio::SimpleAction,
    tasks: Option<Tasks>,
    pending: RefCell<Option<(u64, JsonPreviewRequest)>>,
    rendered: RefCell<Option<JsonPreview>>,
    guards: RefCell<Vec<HandlerGuard>>,
    generation: Cell<u64>,
    running: Cell<bool>,
    closed: Cell<bool>,
}

impl JsonView {
    pub(super) fn new(grid: &DataGrid, retry: impl Fn() + 'static) -> Self {
        let retry = Rc::new(retry);
        let buffer = sourceview5::Buffer::new(None);
        buffer.set_language(sourceview5::LanguageManager::default().language("json").as_ref());
        let config = grid.config();
        let guards = crate::ui::source_dialog::follow_scheme(&buffer, config.as_ref().map(|config| &config.settings));
        let view = sourceview5::View::with_buffer(&buffer);
        view.set_editable(false);
        view.set_cursor_visible(true);
        view.set_monospace(true);
        view.set_show_line_numbers(true);
        view.set_top_margin(8);
        view.set_bottom_margin(8);
        view.set_left_margin(8);
        view.update_property(&[gtk::accessible::Property::Label(&gettext("Rows as JSON"))]);
        let stack = gtk::Stack::new();
        stack.add_named(&gtk::ScrolledWindow::builder().child(&view).build(), Some("content"));
        stack.add_named(&loading_page(), Some("loading"));
        let error = error_page(retry.clone());
        stack.add_named(&error, Some("error"));
        stack.set_visible_child_name("loading");
        let toasts = adw::ToastOverlay::new();
        toasts.set_child(Some(&stack));
        let root = adw::ToolbarView::builder().content(&toasts).build();
        let stale = adw::Banner::new(&gettext("Couldn't refresh rows. Showing the last loaded page."));
        root.add_top_bar(&stale);
        let notice = adw::Banner::new("");
        notice.set_use_markup(false);
        root.add_top_bar(&notice);
        let copy = gio::SimpleAction::new("copy", None);
        copy.set_enabled(false);
        let state = Rc::new(State {
            root,
            stack,
            view,
            error,
            stale: StaleBanner::new(stale, move || retry()),
            notice,
            toasts,
            copy,
            tasks: config.as_ref().map(|config| config.tasks.clone()),
            pending: RefCell::new(None),
            rendered: RefCell::new(None),
            guards: RefCell::new(guards),
            generation: Cell::new(0),
            running: Cell::new(false),
            closed: Cell::new(false),
        });
        let weak = Rc::downgrade(&state);
        state.copy.connect_activate(move |_, _| {
            if let Some(state) = weak.upgrade() {
                state.copy();
            }
        });
        Self { state }
    }

    pub(super) fn widget(&self) -> &gtk::Widget {
        self.state.root.upcast_ref()
    }

    pub(super) fn copy_action(&self) -> &gio::SimpleAction {
        &self.state.copy
    }

    #[cfg(test)]
    pub(super) fn view(&self) -> &sourceview5::View {
        &self.state.view
    }

    pub(super) fn refresh(&self, grid: &DataGrid, presentation: LoadPresentation) {
        let state = &self.state;
        if state.closed.get() {
            return;
        }
        let generation = state.generation.get().wrapping_add(1);
        state.generation.set(generation);
        state.copy.set_enabled(false);
        state.pending.take();
        state.stale.show(presentation.stale.as_ref());
        match presentation.page {
            ContentPage::Spinner => {
                state.clear();
                state.stack.set_visible_child_name("loading");
            }
            ContentPage::Error(failure) => state.show_error(&gettext("Couldn't Load Rows"), &failure.message()),
            ContentPage::Content => {
                state.pending.replace(Some((generation, json_preview(grid))));
                state.start_next();
            }
        }
    }

    pub(super) fn shutdown(&self) {
        self.state.shutdown();
    }
}

impl State {
    fn start_next(self: &Rc<Self>) {
        if self.running.get() || self.closed.get() {
            return;
        }
        let Some((generation, request)) = self.pending.take() else {
            return;
        };
        let Some(tasks) = self.tasks.as_ref() else {
            self.show_error(
                &gettext("Can't Show Rows as JSON"),
                &gettext("Connect to a database first."),
            );
            return;
        };
        self.running.set(true);
        let rendered = tasks.spawn_blocking_task(move || request.render());
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let result = rendered.await;
            let Some(state) = weak.upgrade().filter(|state| !state.closed.get()) else {
                return;
            };
            state.running.set(false);
            // A replaced page or failed read must not be overwritten by its earlier preview.
            if generation == state.generation.get() {
                match result {
                    Ok(Ok(preview)) => state.show(preview),
                    Ok(Err(error)) => state.show_encode_error(error),
                    Err(failure) => {
                        tracing::warn!(%failure, "JSON preview rendering failed");
                        state.show_error(
                            &gettext("Can't Show Rows as JSON"),
                            &gettext("The JSON preview could not be created. Try refreshing the rows."),
                        );
                    }
                }
            }
            state.start_next();
        });
    }

    fn show(&self, preview: JsonPreview) {
        let buffer = self.view.buffer();
        let current = buffer.text(&buffer.start_iter(), &buffer.end_iter(), false);
        if current.as_str() != preview.text {
            buffer.set_text(&preview.text);
        }
        let notice = preview_notice(&preview);
        self.notice.set_title(&notice);
        self.notice.set_revealed(!notice.is_empty());
        self.rendered.replace(Some(preview));
        self.stack.set_visible_child_name("content");
        self.copy.set_enabled(true);
    }

    fn show_encode_error(&self, error: EncodeError) {
        let (EncodeError::Undecodable { column } | EncodeError::NotXmlText { column }) = error;
        self.show_error(
            &gettext("Can't Show Rows as JSON"),
            &gettext_f(
                "The column “{column}” holds a value TablePro couldn't read, so these rows have no JSON to show.",
                &[("column", &column)],
            ),
        );
    }

    fn show_error(&self, title: &str, description: &str) {
        let had_focus = crate::ui::a11y::holds_focus(&self.root);
        let escaped = glib::markup_escape_text(description);
        let changed = self.stack.visible_child_name().as_deref() != Some("error")
            || self.error.description().as_deref() != Some(escaped.as_str());
        self.clear();
        self.error.set_title(title);
        self.error.set_description(Some(&escaped));
        self.stack.set_visible_child_name("error");
        if had_focus && let Some(retry) = self.error.child() {
            retry.grab_focus();
        }
        if changed {
            crate::ui::a11y::announce(
                &self.error,
                &format!("{title}. {description}"),
                gtk::AccessibleAnnouncementPriority::High,
            );
        }
    }

    fn clear(&self) {
        self.rendered.take();
        self.copy.set_enabled(false);
        self.notice.set_revealed(false);
        self.view.buffer().set_text("");
    }

    fn copy(&self) {
        if !self.copy.is_enabled() {
            return;
        }
        let rendered = self.rendered.borrow();
        let Some(preview) = rendered.as_ref() else {
            return;
        };
        let payload = ClipboardPayload {
            text: preview.text.clone(),
            format: ClipboardFormat::Json,
            rows: preview.shown,
            skipped: 0,
            cells: None,
        };
        copy_payload(&self.view, payload, |message| {
            self.toasts.add_toast(adw::Toast::new(message))
        });
    }

    fn shutdown(&self) {
        if self.closed.replace(true) {
            return;
        }
        self.pending.take();
        self.rendered.take();
        self.copy.set_enabled(false);
        self.guards.borrow_mut().clear();
        crate::ui::text_view_teardown::release(&self.view);
    }
}

impl Drop for State {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn loading_page() -> adw::StatusPage {
    adw::StatusPage::builder()
        .title(gettext("Loading…"))
        .child(&adw::Spinner::builder().width_request(32).height_request(32).build())
        .build()
}

fn error_page(retry: Rc<impl Fn() + 'static>) -> adw::StatusPage {
    let button = gtk::Button::with_label(&gettext("Try Again"));
    button.add_css_class("suggested-action");
    button.set_halign(gtk::Align::Center);
    button.connect_clicked(move |_| retry());
    adw::StatusPage::builder()
        .title(gettext("Couldn't Load Rows"))
        .child(&button)
        .build()
}

fn preview_notice(preview: &JsonPreview) -> String {
    let mut notices = Vec::new();
    if preview.shown < preview.total {
        notices.push(gettext_f(
            "{shown} of {total} rows shown. This is a limited preview. Export Rows includes the full page.",
            &[
                ("shown", &preview.shown.to_string()),
                ("total", &preview.total.to_string()),
            ],
        ));
    }
    if preview.deleted > 0 {
        notices.push(ngettext_f(
            "{count} row marked for deletion is not shown.",
            "{count} rows marked for deletion are not shown.",
            preview.deleted as u64,
            &[("count", &preview.deleted.to_string())],
        ));
    }
    notices.join(" ")
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::test_support::wait_until;
    use crate::ui::data_grid::test_grid::{Grid, WAIT, page, two_text_columns, two_text_values};
    use crate::ui::tab_load::{ContentLoad, LoadFailure};

    fn text(view: &JsonView) -> String {
        let buffer = view.view().buffer();
        buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string()
    }

    #[gtk4::test]
    fn only_the_latest_preview_lands_and_unchanged_text_keeps_selection() {
        let grid = Grid::open(two_text_columns(), two_text_values());
        let view = JsonView::new(&grid.grid, || {});
        view.refresh(&grid.grid, ContentLoad::Loaded.presentation());
        grid.grid.replace_rows(page(3..5), 0);
        view.refresh(&grid.grid, ContentLoad::Loaded.presentation());
        assert!(!view.copy_action().is_enabled());
        wait_until(WAIT, || view.copy_action().is_enabled()).expect("the latest preview");
        assert!(text(&view).contains("row 3"));
        assert!(!text(&view).contains("\"A\""));

        let buffer = view.view().buffer();
        buffer.select_range(&buffer.iter_at_offset(1), &buffer.iter_at_offset(4));
        view.refresh(&grid.grid, ContentLoad::Loaded.presentation());
        wait_until(WAIT, || view.copy_action().is_enabled()).expect("the unchanged preview");
        let (start, end) = buffer.selection_bounds().expect("selection survived");
        assert_eq!((start.offset(), end.offset()), (1, 4));
        view.shutdown();
    }

    #[gtk4::test]
    fn a_render_cannot_replace_a_read_error_or_keep_a_closed_view_alive() {
        let grid = Grid::open(two_text_columns(), two_text_values());
        let view = JsonView::new(&grid.grid, || {});
        view.refresh(&grid.grid, ContentLoad::Loaded.presentation());
        let failed = ContentLoad::Failed(LoadFailure::Page(Arc::new(tablepro_session::OperationError::Closed)));
        view.refresh(&grid.grid, failed.presentation());
        wait_until(WAIT, || !view.state.running.get()).expect("the obsolete render finished");
        assert_eq!(view.state.stack.visible_child_name().as_deref(), Some("error"));
        assert!(!view.copy_action().is_enabled());
        assert!(text(&view).is_empty());

        view.refresh(&grid.grid, ContentLoad::Loaded.presentation());
        let weak = view.view().downgrade();
        view.shutdown();
        drop(view);
        assert!(
            weak.upgrade().is_none(),
            "a background render retained the closed editor"
        );
    }
}
