use std::cell::Cell;
use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::{adw, gtk};

pub(super) fn install(split: &adw::OverlaySplitView) {
    let shown = split.shows_sidebar();
    let (Some(sidebar), Some(content)) = (split.sidebar(), split.content()) else {
        return;
    };
    split.set_sidebar(gtk::Widget::NONE);
    split.set_content(gtk::Widget::NONE);
    let paned = gtk::Paned::builder()
        .orientation(gtk::Orientation::Horizontal)
        .wide_handle(true)
        .resize_start_child(false)
        .shrink_start_child(false)
        .resize_end_child(true)
        .shrink_end_child(false)
        .position(260)
        .end_child(&content)
        .build();
    paned.set_widget_name("database-sidebar-divider");
    split.set_content(Some(&paned));
    place_sidebar(split, &paned, &sidebar, 260);
    let preferred = Rc::new(Cell::new(260));
    let saved = preferred.clone();
    let divider = paned.clone();
    let sidebar_for_collapse = sidebar.clone();
    let collapsed_width = saved.clone();
    split.connect_collapsed_notify(move |split| {
        place_sidebar(split, &divider, &sidebar_for_collapse, collapsed_width.get());
    });
    let divider = paned.clone();
    let sidebar_for_show = sidebar.clone();
    split.connect_show_sidebar_notify(move |split| {
        if !split.is_collapsed() {
            sidebar_for_show.set_visible(split.shows_sidebar());
        }
        if split.shows_sidebar() {
            divider.set_position(preferred.get());
        }
    });
    let weak_split = split.downgrade();
    paned.connect_position_notify(move |paned| {
        let Some(split) = weak_split.upgrade() else {
            return;
        };
        if split.is_collapsed() || !split.shows_sidebar() || paned.width() == 0 {
            return;
        }
        let limit = paned.width().saturating_sub(600).clamp(220, 520);
        let position = paned.position().clamp(220, limit);
        saved_position(paned, position, &saved);
    });
    split.set_show_sidebar(shown);
    sidebar.set_visible(shown || split.is_collapsed());
}

fn saved_position(paned: &gtk::Paned, position: i32, saved: &Cell<i32>) {
    saved.set(position);
    if paned.position() != position {
        paned.set_position(position);
    }
}

fn place_sidebar(split: &adw::OverlaySplitView, paned: &gtk::Paned, sidebar: &gtk::Widget, width: i32) {
    if split.is_collapsed() {
        split.set_max_sidebar_width(280.0);
        split.set_min_sidebar_width(220.0);
        paned.set_start_child(gtk::Widget::NONE);
        split.set_sidebar(Some(sidebar));
        sidebar.set_visible(true);
        return;
    }
    split.set_sidebar(gtk::Widget::NONE);
    split.set_min_sidebar_width(1.0);
    split.set_max_sidebar_width(1.0);
    paned.set_start_child(Some(sidebar));
    sidebar.set_visible(split.shows_sidebar());
    paned.set_position(width);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn the_sidebar_resizes_when_docked_and_keeps_the_narrow_overlay() {
        adw::init().unwrap();
        let sidebar = gtk::Box::new(gtk::Orientation::Vertical, 0);
        sidebar.set_width_request(220);
        let content = gtk::Box::new(gtk::Orientation::Vertical, 0);
        content.set_width_request(600);
        let split = adw::OverlaySplitView::builder()
            .sidebar(&sidebar)
            .content(&content)
            .show_sidebar(true)
            .build();
        install(&split);
        let paned = split.content().and_downcast::<gtk::Paned>().unwrap();
        assert_eq!(paned.start_child().as_ref(), Some(sidebar.upcast_ref()));
        assert!(paned.is_wide_handle());
        paned.set_position(360);
        assert_eq!(paned.position(), 360);
        split.set_show_sidebar(false);
        assert!(!sidebar.is_visible());
        split.set_collapsed(true);
        assert!(paned.start_child().is_none());
        assert_eq!(split.sidebar().as_ref(), Some(sidebar.upcast_ref()));
        assert!(!split.shows_sidebar());
        split.set_show_sidebar(true);
        split.set_collapsed(false);
        assert!(split.sidebar().is_none());
        assert_eq!(paned.start_child().as_ref(), Some(sidebar.upcast_ref()));
        assert!(sidebar.is_visible());
    }
}

#[cfg(test)]
mod allocated_tests {
    use super::*;

    fn settle(window: &adw::ApplicationWindow) {
        let ready = Rc::new(Cell::new(false));
        let observed = ready.clone();
        let frames = Cell::new(0);
        window.add_tick_callback(move |_, _| {
            frames.set(frames.get() + 1);
            if frames.get() < 2 {
                return gtk::glib::ControlFlow::Continue;
            }
            observed.set(true);
            gtk::glib::ControlFlow::Break
        });
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !ready.get() {
            assert!(std::time::Instant::now() < deadline);
            gtk::glib::MainContext::default().iteration(false);
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn an_allocated_divider_preserves_workspace_space_and_moves_through_the_breakpoint() {
        adw::init().unwrap();
        let application = adw::Application::builder()
            .application_id("com.tablepro.linux.sidebar-layout-test")
            .build();
        application.register(None::<&gtk::gio::Cancellable>).unwrap();
        let sidebar = gtk::Box::new(gtk::Orientation::Vertical, 0);
        sidebar.set_width_request(220);
        let content = gtk::Box::new(gtk::Orientation::Vertical, 0);
        content.set_width_request(600);
        let split = adw::OverlaySplitView::builder()
            .sidebar(&sidebar)
            .content(&content)
            .show_sidebar(false)
            .build();
        install(&split);
        let window = adw::ApplicationWindow::builder()
            .application(&application)
            .default_width(1200)
            .default_height(700)
            .content(&split)
            .build();
        let breakpoint = adw::Breakpoint::new(adw::BreakpointCondition::new_length(
            adw::BreakpointConditionLengthType::MaxWidth,
            960.0,
            adw::LengthUnit::Px,
        ));
        breakpoint.add_setter(&split, "collapsed", Some(&true.into()));
        breakpoint.add_setter(&split, "show-sidebar", Some(&false.into()));
        window.add_breakpoint(breakpoint);
        window.present();
        settle(&window);
        split.set_show_sidebar(true);
        settle(&window);
        let paned = split.content().and_downcast::<gtk::Paned>().unwrap();
        assert!(!split.is_collapsed());
        assert!(split.shows_sidebar());
        assert!(
            paned.compute_bounds(&split).unwrap().x().abs() <= 1.0,
            "the empty overlay sidebar must not reserve another column"
        );
        paned.set_position(900);
        settle(&window);
        assert!(
            paned.position() <= 520,
            "position={} width={} shown={} collapsed={}",
            paned.position(),
            paned.width(),
            split.shows_sidebar(),
            split.is_collapsed()
        );
        assert!(sidebar.width() <= 520);
        assert!(content.width() >= 600);
        window.set_default_size(800, 700);
        settle(&window);
        assert!(split.is_collapsed());
        assert!(paned.start_child().is_none());
        assert!(!split.shows_sidebar());
        split.set_show_sidebar(true);
        settle(&window);
        assert!(split.shows_sidebar());
        window.set_default_size(1200, 700);
        settle(&window);
        assert!(!split.is_collapsed());
        assert!(paned.start_child().is_some());
        assert!(content.width() >= 600);
        window.close();
    }
}
