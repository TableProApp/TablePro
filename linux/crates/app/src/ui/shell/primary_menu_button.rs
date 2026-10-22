use gtk4 as gtk;
use gtk4::prelude::*;

/// The ids of the menus in `gtk/menus.ui`.
pub(crate) const PRIMARY_MENU: &str = "primary_menu";
pub(crate) const TAB_OVERVIEW_MENU: &str = "tab_overview_menu";

/// A menu GtkApplication read from `gtk/menus.ui` at startup. A missing
/// one is a broken build, not a state the user can fix.
pub(crate) fn app_menu(app: Option<&gtk::Application>, id: &str) -> Option<gio::MenuModel> {
    let menu = app.and_then(|app| app.menu_by_id(id));
    if menu.is_none() {
        tracing::error!(
            id,
            "the application has no such menu; is gtk/menus.ui in the resources?"
        );
    }
    menu.map(|menu| menu.upcast())
}

/// The header bar's main menu, which F10 opens.
pub(crate) fn primary_menu_button(app: Option<&gtk::Application>) -> gtk::MenuButton {
    let button = gtk::MenuButton::builder()
        .icon_name(crate::ui::icons::OPEN_MENU)
        .primary(true)
        .build();
    crate::ui::a11y::describe_icon_button(&button, &crate::i18n::gettext("Main Menu"), None);
    match app_menu(app, PRIMARY_MENU) {
        Some(menu) => button.set_menu_model(Some(&menu)),
        None => button.set_sensitive(false),
    }
    button
}

#[cfg(test)]
mod tests {
    use super::*;

    #[gtk4::test]
    fn without_its_menu_the_button_is_insensitive() {
        let button = primary_menu_button(None);

        assert!(!button.is_sensitive());
        assert!(button.is_primary());
        assert_eq!(button.tooltip_text().as_deref(), Some("Main Menu"));
    }
}
