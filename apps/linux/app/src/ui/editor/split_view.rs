use relm4::gtk::prelude::*;
use relm4::{ComponentSender, gtk};
use sourceview5::prelude::*;

use super::{DropGeneration, SqlEditor, SqlEditorInput};

pub(crate) struct SplitEditorView {
    paned: gtk::Paned,
    secondary_scroll: gtk::ScrolledWindow,
    secondary_view: sourceview5::View,
}

type EditorShortcut = (&'static str, fn() -> SqlEditorInput);

impl SplitEditorView {
    pub(crate) fn install(
        holder: &gtk::Box,
        primary_scroll: &gtk::ScrolledWindow,
        primary: &sourceview5::View,
    ) -> Self {
        let secondary_view = sourceview5::View::builder()
            .show_line_numbers(primary.shows_line_numbers())
            .monospace(true)
            .auto_indent(true)
            .highlight_current_line(true)
            .tab_width(primary.tab_width())
            .top_margin(8)
            .bottom_margin(8)
            .left_margin(8)
            .right_margin(8)
            .build();
        secondary_view.set_buffer(Some(&primary.buffer()));
        let secondary_scroll = gtk::ScrolledWindow::builder()
            .hexpand(true)
            .vexpand(true)
            .min_content_width(240)
            .child(&secondary_view)
            .build();
        let paned = gtk::Paned::new(gtk::Orientation::Horizontal);
        paned.set_vexpand(true);
        paned.set_hexpand(true);
        paned.set_wide_handle(true);
        paned.set_position(400);
        holder.remove(primary_scroll);
        paned.set_start_child(Some(primary_scroll));
        paned.set_end_child(Some(&secondary_scroll));
        holder.append(&paned);
        secondary_scroll.set_visible(false);
        Self {
            paned,
            secondary_scroll,
            secondary_view,
        }
    }

    pub(crate) fn secondary_view(&self) -> &sourceview5::View {
        &self.secondary_view
    }

    pub(crate) fn set_visible(&self, visible: bool) {
        self.secondary_scroll.set_visible(visible);
        if visible {
            let width = self.paned.width();
            self.paned.set_position(if width > 0 { width / 2 } else { 400 });
        }
    }
}

pub(crate) fn install_shortcuts(view: &sourceview5::View, sender: &ComponentSender<SqlEditor>) {
    let shortcuts: [EditorShortcut; 5] = [
        ("<Primary>Return", || SqlEditorInput::Run),
        ("Escape", || SqlEditorInput::Cancel),
        ("<Primary><Shift>f", || SqlEditorInput::Format),
        ("<Primary><Shift>Return", || SqlEditorInput::RunAtCursor),
        ("<Primary>slash", || SqlEditorInput::ToggleLineComment),
    ];
    let controller = gtk::ShortcutController::new();
    for (trigger, input) in shortcuts {
        let sender = sender.clone();
        controller.add_shortcut(
            gtk::Shortcut::builder()
                .trigger(&crate::ui::shortcut::parse(trigger))
                .action(&gtk::CallbackAction::new(move |_, _| {
                    sender.input(input());
                    gtk::glib::Propagation::Stop
                }))
                .build(),
        );
    }
    for (trigger, forward) in [("<Alt><Shift>Down", true), ("<Alt><Shift>Up", false)] {
        let sender = sender.clone();
        controller.add_shortcut(
            gtk::Shortcut::builder()
                .trigger(&crate::ui::shortcut::parse(trigger))
                .action(&gtk::CallbackAction::new(move |_, _| {
                    sender.input(SqlEditorInput::JumpStatement { forward });
                    gtk::glib::Propagation::Stop
                }))
                .build(),
        );
    }
    view.add_controller(controller);
}

pub(crate) fn install_drop_target(
    view: &sourceview5::View,
    sender: &ComponentSender<SqlEditor>,
    generation: &std::rc::Rc<DropGeneration>,
) {
    let target = gtk::DropTarget::new(gtk::gio::File::static_type(), gtk::gdk::DragAction::COPY);
    let sender = sender.clone();
    let generation = generation.clone();
    target.connect_drop(move |_, value, _, _| {
        let Ok(file) = value.get::<gtk::gio::File>() else {
            return false;
        };
        let Some(path) = file.path() else {
            return false;
        };
        let sender = sender.clone();
        let request = generation.begin();
        std::thread::spawn(move || {
            let message = match super::read_sql_text(&path, super::MAX_SQL_FILE_BYTES) {
                Ok(text) => SqlEditorInput::InsertDroppedSql { request, text },
                Err(message) => SqlEditorInput::DroppedSqlFailed { request, message },
            };
            sender.input(message);
        });
        true
    });
    view.add_controller(target);
}

#[cfg(test)]
mod tests {
    use super::*;
    use relm4::gtk;

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn split_editor_views_share_buffer_and_retain_text_across_toggles() {
        gtk::init().expect("initialize GTK");
        let holder = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let primary = sourceview5::View::new();
        let buffer = sourceview5::Buffer::new(None::<&gtk::TextTagTable>);
        buffer.set_text(&query("SELECT 1;"));
        primary.set_buffer(Some(&buffer));
        let primary_scroll = gtk::ScrolledWindow::new();
        primary_scroll.set_child(Some(&primary));
        holder.append(&primary_scroll);
        let split = SplitEditorView::install(&holder, &primary_scroll, &primary);

        assert!(!split.secondary_view().is_visible());
        split.set_visible(true);
        let window = gtk::Window::new();
        window.set_default_size(900, 600);
        window.set_child(Some(&holder));
        window.present();
        let context = gtk::glib::MainContext::default();
        for _ in 0..10 {
            while context.pending() {
                context.iteration(false);
            }
        }
        let updated_query = query("SELECT 2;");
        split.secondary_view().buffer().set_text(&updated_query);
        let (start, end) = primary.buffer().bounds();
        assert_eq!(primary.buffer().text(&start, &end, false), updated_query);
        let primary_adjustment = primary_scroll.vadjustment();
        let secondary_adjustment = split.secondary_scroll.vadjustment();
        primary_adjustment.set_value(20.0);
        secondary_adjustment.set_value(40.0);
        let primary_value = primary_adjustment.value();
        let secondary_value = secondary_adjustment.value();
        split.set_visible(false);
        split.set_visible(true);
        while context.pending() {
            context.iteration(false);
        }

        let (start, end) = split.secondary_view().buffer().bounds();
        assert_eq!(split.secondary_view().buffer().text(&start, &end, false), updated_query);
        assert_eq!(primary_adjustment.value(), primary_value);
        assert_eq!(secondary_adjustment.value(), secondary_value);
        assert!(split.secondary_view().is_visible());
        window.close();
    }

    fn query(first: &str) -> String {
        std::iter::once(first.to_string())
            .chain((1..200).map(|line| format!("SELECT {line};")))
            .collect::<Vec<_>>()
            .join("\n")
    }
}
