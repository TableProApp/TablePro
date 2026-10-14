use super::tab_title::TabTitle;

/// What the window is called: in the window list and Alt+Tab, and in its
/// header bar's title and subtitle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct WindowTitle {
    pub window: String,
    pub heading: String,
    pub subtitle: String,
}

/// Named the way GNOME Text Editor names its window, "[document]
/// ([location]) - Text Editor": the tab in front, then the connection.
pub(crate) fn resolve_window_title(
    active: Option<&TabTitle>,
    connection: &str,
    driver: &str,
    read_only: bool,
) -> WindowTitle {
    let (window, heading, subtitle) = match active {
        Some(tab) => (
            crate::i18n::gettext_f(
                "{tab} ({connection}) - TablePro",
                &[("tab", &tab.label), ("connection", connection)],
            ),
            tab.label.clone(),
            connection.to_owned(),
        ),
        None => (
            crate::i18n::gettext_f("{connection} - TablePro", &[("connection", connection)]),
            connection.to_owned(),
            driver.to_owned(),
        ),
    };
    let subtitle = match read_only {
        true => crate::i18n::gettext_f("{name} · Read-Only", &[("name", &subtitle)]),
        false => subtitle,
    };
    WindowTitle {
        window,
        heading,
        subtitle,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tab(label: &str) -> TabTitle {
        TabTitle {
            label: label.to_owned(),
            tooltip: None,
        }
    }

    #[test]
    fn window_title_names_tab_and_connection_without_em_dash() {
        let title = resolve_window_title(Some(&tab("orders")), "Shop", "PostgreSQL", false);

        assert_eq!(title.window, "orders (Shop) - TablePro");
        assert_eq!(title.heading, "orders");
        assert_eq!(title.subtitle, "Shop");
        assert!(!title.window.contains('\u{2014}'));
        assert!(!title.window.contains('•'));
    }

    #[test]
    fn with_no_tab_the_connection_heads_the_window() {
        let title = resolve_window_title(None, "Shop", "PostgreSQL", false);

        assert_eq!(title.window, "Shop - TablePro");
        assert_eq!(title.heading, "Shop");
        assert_eq!(title.subtitle, "PostgreSQL");
    }

    #[test]
    fn read_only_subtitle() {
        assert_eq!(
            resolve_window_title(None, "Shop", "PostgreSQL", true).subtitle,
            "PostgreSQL · Read-Only"
        );
        assert_eq!(
            resolve_window_title(Some(&tab("orders")), "Shop", "PostgreSQL", true).subtitle,
            "Shop · Read-Only"
        );
    }
}
