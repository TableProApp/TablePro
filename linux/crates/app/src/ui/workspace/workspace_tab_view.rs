use libadwaita as adw;

/// AdwTabView runs its shortcuts in a capture-phase, global controller,
/// so Ctrl+Home and Ctrl+End would switch tabs before the SQL editor or
/// a grid saw them. GNOME Text Editor removes the same four.
const CHILD_NAVIGATION_KEYS: adw::TabViewShortcuts = adw::TabViewShortcuts::CONTROL_HOME
    .union(adw::TabViewShortcuts::CONTROL_END)
    .union(adw::TabViewShortcuts::CONTROL_SHIFT_HOME)
    .union(adw::TabViewShortcuts::CONTROL_SHIFT_END);

pub(super) fn new_workspace_tab_view() -> adw::TabView {
    let view = adw::TabView::new();
    view.remove_shortcuts(CHILD_NAVIGATION_KEYS);
    view
}

#[cfg(test)]
mod tests {
    use super::*;

    #[gtk4::test]
    fn workspace_tab_view_leaves_buffer_navigation_keys_to_children() {
        adw::init().expect("libadwaita initialises under the test backend");

        let shortcuts = new_workspace_tab_view().shortcuts();

        assert!(
            !shortcuts.intersects(CHILD_NAVIGATION_KEYS),
            "the tab view still takes {:?}",
            shortcuts & CHILD_NAVIGATION_KEYS
        );
        let switching = adw::TabViewShortcuts::CONTROL_TAB
            | adw::TabViewShortcuts::CONTROL_SHIFT_TAB
            | adw::TabViewShortcuts::CONTROL_PAGE_UP
            | adw::TabViewShortcuts::CONTROL_PAGE_DOWN
            | adw::TabViewShortcuts::CONTROL_SHIFT_PAGE_UP
            | adw::TabViewShortcuts::CONTROL_SHIFT_PAGE_DOWN
            | adw::TabViewShortcuts::ALT_DIGITS
            | adw::TabViewShortcuts::ALT_ZERO;
        assert!(
            shortcuts.contains(switching),
            "a tab switching key was lost: {:?}",
            switching - shortcuts
        );
    }
}
