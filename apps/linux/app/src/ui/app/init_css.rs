use relm4::gtk;

pub(super) fn install_pending_change_css() {
    // Custom CSS for pending-changeset visual states. Native
    // Adwaita classes (.warning, .success, .error) don't compose
    // cleanly on grid cells (background colour washes the row);
    // these rules use the same accent-tinted alpha approach
    // GNOME Builder uses for diff markers.
    if let Some(display) = gtk::gdk::Display::default() {
        let provider = gtk::CssProvider::new();
        provider.load_from_resource("/com/tablepro/linux/style.css");
        gtk::style_context_add_provider_for_display(&display, &provider, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
    }
}
