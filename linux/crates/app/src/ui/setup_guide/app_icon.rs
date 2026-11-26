// An installed app's icon, from its desktop entry. Flatpak hides the host's entries, so the fallback shows there.

use gtk4::gio;
use gtk4::prelude::*;
use tablepro_foreign_import::ForeignApp;

pub(super) fn app_icon(app: ForeignApp) -> Option<gio::Icon> {
    let display_name = app.display_name();
    gio_unix::DesktopAppInfo::search(display_name)
        .into_iter()
        .flatten()
        .filter_map(|id| gio_unix::DesktopAppInfo::new(&id))
        .find(|info| names_match(&info.name(), display_name))
        .and_then(|info| info.icon())
}

// An edition's entry names the app and then the edition, so "Name Community" counts and "Named" does not.
fn names_match(entry_name: &str, display_name: &str) -> bool {
    entry_name
        .strip_prefix(display_name)
        .is_some_and(|rest| rest.is_empty() || rest.starts_with(' '))
}

#[cfg(test)]
mod tests {
    use super::names_match;

    #[test]
    fn an_entry_matches_the_app_name_alone_or_followed_by_an_edition() {
        assert!(names_match("Source App", "Source App"));
        assert!(names_match("Source App Community", "Source App"));
        assert!(!names_match("Source Apps", "Source App"));
        assert!(!names_match("Other Source App", "Source App"));
        assert!(!names_match("Source", "Source App"));
    }
}
