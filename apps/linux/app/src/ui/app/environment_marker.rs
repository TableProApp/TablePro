use relm4::adw;
use relm4::adw::prelude::*;
use relm4::gtk;
use tablepro_core::Environment;

pub(super) const PRODUCTION_HEADER_CLASS: &str = "tp-production";

pub(super) fn is_production(environment: Option<Environment>) -> bool {
    environment == Some(Environment::Prod)
}

pub(super) fn apply(badge: &gtk::Label, header_bar: &adw::HeaderBar, environment: Option<Environment>) {
    let production = is_production(environment);
    badge.set_visible(production);
    if production {
        header_bar.add_css_class(PRODUCTION_HEADER_CLASS);
    } else {
        header_bar.remove_css_class(PRODUCTION_HEADER_CLASS);
    }
}

pub(super) fn os_window_title(title: String, environment: Option<Environment>, unsaved: bool) -> String {
    let marked = if is_production(environment) {
        format!("{} {title}", crate::tr!("[Production]"))
    } else {
        title
    };
    if unsaved { format!("• {marked}") } else { marked }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_production_connection_is_marked() {
        for environment in [Environment::Local, Environment::Dev, Environment::Staging] {
            assert!(!is_production(Some(environment)), "{environment:?}");
        }
        assert!(is_production(Some(Environment::Prod)));
        assert!(!is_production(None), "the welcome screen has no connection to mark");
    }

    #[test]
    fn the_window_title_carries_the_marker_before_the_unsaved_dot() {
        let title = || "orders · prod-db — BookiE".to_string();
        assert_eq!(
            os_window_title(title(), Some(Environment::Prod), false),
            "[Production] orders · prod-db — BookiE"
        );
        assert_eq!(
            os_window_title(title(), Some(Environment::Prod), true),
            "• [Production] orders · prod-db — BookiE"
        );
        assert_eq!(
            os_window_title(title(), Some(Environment::Staging), true),
            "• orders · prod-db — BookiE"
        );
        assert_eq!(os_window_title("BookiE".into(), None, false), "BookiE");
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn the_badge_and_header_tint_follow_the_connection_environment() {
        relm4::adw::init().unwrap();
        let badge = gtk::Label::new(Some("Production"));
        let header_bar = adw::HeaderBar::new();

        apply(&badge, &header_bar, Some(Environment::Prod));
        assert!(badge.is_visible());
        assert!(header_bar.has_css_class(PRODUCTION_HEADER_CLASS));

        apply(&badge, &header_bar, Some(Environment::Dev));
        assert!(!badge.is_visible());
        assert!(!header_bar.has_css_class(PRODUCTION_HEADER_CLASS));

        apply(&badge, &header_bar, Some(Environment::Prod));
        apply(&badge, &header_bar, None);
        assert!(!badge.is_visible(), "disconnecting clears the marker");
        assert!(!header_bar.has_css_class(PRODUCTION_HEADER_CLASS));
    }
}
