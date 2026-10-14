pub(crate) const SCHEMA_FILTER_ICON_NAME: &str = "view-list-symbolic";
pub(crate) const EXPLAIN_TREE_ICON_NAME: &str = "view-list-symbolic";
pub(crate) const EXPLAIN_TEXT_ICON_NAME: &str = "text-x-generic-symbolic";

#[cfg(test)]
mod tests {
    use super::*;
    use relm4::gtk;

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn schema_filter_icon_exists_in_the_active_theme() {
        gtk::init().unwrap();
        let display = gtk::gdk::Display::default().unwrap();
        let theme = gtk::IconTheme::for_display(&display);

        assert!(theme.has_icon(SCHEMA_FILTER_ICON_NAME));
    }
}
