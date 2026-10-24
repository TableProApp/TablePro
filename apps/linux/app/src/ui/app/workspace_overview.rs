use relm4::adw::prelude::*;
use relm4::{adw, gtk};

pub(super) fn build_workspace_tab_overview(view: &adw::TabView, child: &impl IsA<gtk::Widget>) -> adw::TabOverview {
    adw::TabOverview::builder()
        .view(view)
        .enable_new_tab(true)
        .enable_search(true)
        .show_end_title_buttons(false)
        .child(child)
        .build()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn the_tab_overview_hides_duplicate_window_close_controls() {
        gtk::init().unwrap();
        let view = adw::TabView::new();
        let child = gtk::Box::new(gtk::Orientation::Vertical, 0);

        let overview = build_workspace_tab_overview(&view, &child);

        assert!(!overview.shows_end_title_buttons());
    }
}
