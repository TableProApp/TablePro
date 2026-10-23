use libadwaita::prelude::*;

pub(super) fn restore_on_close(
    dialog: &libadwaita::Dialog,
    view: &gtk4::ColumnView,
    on_restored: impl Fn(&gtk4::ColumnView) + 'static,
) {
    let on_restored = std::rc::Rc::new(on_restored);
    dialog.connect_closed({
        let view = view.downgrade();
        move |_| {
            let origin = view
                .upgrade()
                .and_then(|view| view.root())
                .and_then(|root| root.focus())
                .map(|focus| focus.downgrade());
            let view = view.clone();
            let on_restored = on_restored.clone();
            gtk4::glib::idle_add_local_once(move || {
                let Some(view) = view.upgrade().filter(WidgetExt::is_mapped) else {
                    return;
                };
                let current = view.root().and_then(|root| root.focus());
                let origin = origin.and_then(|focus| focus.upgrade());
                if current.as_ref() != origin.as_ref() {
                    return;
                }
                on_restored(&view);
                focus_navigation_row(&view);
            });
        }
    });
}

fn focus_navigation_row(view: &gtk4::ColumnView) {
    view.grab_focus();
    let Some(focus) = view.root().and_then(|root| root.focus()) else {
        return;
    };
    if !focus.is::<gtk4::Label>() || !focus.is_ancestor(view) {
        return;
    }
    if let Some(cell) = focus
        .parent()
        .filter(|parent| parent.accessible_role() == gtk4::AccessibleRole::GridCell && parent.is_focusable())
    {
        cell.child_focus(gtk4::DirectionType::TabBackward);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::time::{Duration, Instant};
    use tablepro_core::{ColumnInfo, QueryResult, Value};

    fn settle() {
        let context = gtk4::glib::MainContext::default();
        let deadline = Instant::now() + Duration::from_millis(150);
        while Instant::now() < deadline {
            while context.iteration(false) {}
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    fn grid(count: usize) -> gtk4::ColumnView {
        let result = Arc::new(QueryResult {
            columns: vec![ColumnInfo {
                name: "value".into(),
                data_type: "TEXT".into(),
                nullable: true,
                primary_key: false,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
                comment: None,
                collation: None,
                enum_type: None,
                domain_type: None,
            }],
            rows: (0..count).map(|index| vec![Value::Text(index.to_string())]).collect(),
            truncated: false,
        });
        super::super::build_column_view(
            &result,
            &[],
            "",
            None,
            None,
            None,
            None,
            None,
            super::super::TabGridContext::default(),
            None,
            Arc::new(crate::services::database_service::DatabaseService::new_isolated()),
        )
        .0
    }

    fn wait_until(condition: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(5);
        let context = gtk4::glib::MainContext::default();
        while !condition() {
            assert!(Instant::now() < deadline, "focus transition did not finish");
            while context.iteration(false) {}
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    fn window_with_grid(view: &gtk4::ColumnView) -> (libadwaita::Window, gtk4::Button, gtk4::Button) {
        let origin = gtk4::Button::with_label("Origin");
        let later = gtk4::Button::with_label("Later choice");
        let content = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
        content.append(&origin);
        content.append(&later);
        content.append(&gtk4::ScrolledWindow::builder().child(view).vexpand(true).build());
        let window = libadwaita::Window::builder()
            .default_width(480)
            .default_height(300)
            .content(&content)
            .build();
        window.present();
        settle();
        (window, origin, later)
    }

    fn restoration_count(dialog: &libadwaita::Dialog, view: &gtk4::ColumnView) -> std::rc::Rc<std::cell::Cell<usize>> {
        let count = std::rc::Rc::new(std::cell::Cell::new(0));
        restore_on_close(dialog, view, {
            let count = count.clone();
            move |view| {
                count.set(count.get() + 1);
                let column = view.columns().item(0).and_downcast::<gtk4::ColumnViewColumn>();
                view.scroll_to(0, column.as_ref(), gtk4::ListScrollFlags::FOCUS, None);
            }
        });
        count
    }

    fn assert_close_focus(animations: bool, hidden: bool, moved: bool) {
        gtk4::Settings::default().unwrap().set_gtk_enable_animations(animations);
        let view = grid(1);
        let (window, origin, later) = window_with_grid(&view);
        origin.grab_focus();
        let entry = gtk4::Entry::new();
        let dialog = libadwaita::Dialog::builder().child(&entry).build();
        let restored = restoration_count(&dialog, &view);
        if moved {
            let later = later.downgrade();
            dialog.connect_closed(move |_| {
                if let Some(later) = later.upgrade() {
                    later.grab_focus();
                }
            });
        }
        dialog.present(Some(&view));
        entry.grab_focus();
        wait_until(|| gtk4::prelude::RootExt::focus(&window).is_some_and(|focus| focus.is_ancestor(&entry)));
        view.set_visible(!hidden);
        dialog.close();
        wait_until(|| {
            gtk4::prelude::RootExt::focus(&window).is_some_and(|focus| {
                if moved {
                    focus == later.clone().upcast::<gtk4::Widget>()
                } else if hidden {
                    focus == origin.clone().upcast::<gtk4::Widget>()
                } else {
                    focus.is_ancestor(&view) && !focus.is::<gtk4::Label>()
                }
            })
        });
        settle();
        assert_eq!(restored.get(), usize::from(!hidden && !moved));
        let focus = gtk4::prelude::RootExt::focus(&window).unwrap();
        if moved {
            assert_eq!(focus, later.upcast::<gtk4::Widget>());
        } else if hidden {
            assert_eq!(focus, origin.upcast::<gtk4::Widget>());
        } else {
            assert!(focus.is_ancestor(&view));
            assert!(!focus.is::<gtk4::Label>());
            assert_eq!(super::super::focused_cell_identity(&view), Some((0, 0, Vec::new())));
        }
        window.close();
        settle();
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn closing_a_search_restores_navigation_only_to_a_mapped_grid() {
        libadwaita::init().unwrap();
        for animations in [false, true] {
            for (hidden, moved) in [(false, false), (true, false), (false, true)] {
                assert_close_focus(animations, hidden, moved);
            }
        }
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn virtualized_rows_keep_the_focused_cells_identity_when_revealed() {
        libadwaita::init().unwrap();
        let view = grid(5000);
        let (window, _, _) = window_with_grid(&view);
        let column = view.columns().item(0).and_downcast::<gtk4::ColumnViewColumn>().unwrap();
        for position in [4999, 0, 2499, 0] {
            view.scroll_to(position, Some(&column), gtk4::ListScrollFlags::FOCUS, None);
            focus_navigation_row(&view);
            wait_until(|| super::super::focused_cell_identity(&view) == Some((position, 0, Vec::new())));
            settle();
        }
        window.close();
        settle();
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn a_search_dialog_does_not_keep_the_grid_alive() {
        libadwaita::init().unwrap();
        let view = grid(1);
        let weak = view.downgrade();
        let dialog = libadwaita::Dialog::new();
        restore_on_close(&dialog, &view, |_| {});
        drop(view);
        assert!(weak.upgrade().is_none());
    }
}
