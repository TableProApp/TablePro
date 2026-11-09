use gtk4::prelude::*;
use sourceview5::prelude::*;

const LIGHT_FALLBACK: &str = "Adwaita";
const DARK_FALLBACK: &str = "Adwaita-dark";

// An empty preference follows the desktop; every installed id is an exact choice.
pub(crate) fn resolve_id(manager: &sourceview5::StyleSchemeManager, preferred: &str, dark: bool) -> String {
    if manager.scheme(preferred).is_some() {
        preferred.to_owned()
    } else if dark {
        DARK_FALLBACK.to_owned()
    } else {
        LIGHT_FALLBACK.to_owned()
    }
}

pub(crate) fn apply(view: &sourceview5::View, preferred: &str) {
    let Some(scheme) = scheme(preferred) else {
        return;
    };
    if let Ok(buffer) = view.buffer().downcast::<sourceview5::Buffer>() {
        buffer.set_style_scheme(Some(&scheme));
    }
}

pub(crate) fn scheme(preferred: &str) -> Option<sourceview5::StyleScheme> {
    let manager = sourceview5::StyleSchemeManager::default();
    let dark = libadwaita::StyleManager::default().is_dark();
    manager.scheme(&resolve_id(&manager, preferred, dark))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[gtk4::test]
    fn automatic_scheme_follows_the_desktop() {
        let manager = sourceview5::StyleSchemeManager::default();

        let dark = resolve_id(&manager, "", true);
        let light = resolve_id(&manager, "", false);

        assert_eq!(dark, DARK_FALLBACK);
        assert_eq!(light, LIGHT_FALLBACK);
    }

    #[gtk4::test]
    fn a_picked_scheme_is_drawn_as_picked_whatever_the_desktop() {
        let manager = sourceview5::StyleSchemeManager::default();

        for id in manager.scheme_ids() {
            for dark in [false, true] {
                assert_eq!(resolve_id(&manager, &id, dark), id, "desktop dark: {dark}");
            }
        }
    }

    #[gtk4::test]
    fn unknown_scheme_falls_back_to_the_adwaita_pair() {
        let manager = sourceview5::StyleSchemeManager::default();

        assert_eq!(resolve_id(&manager, "not-a-scheme", true), DARK_FALLBACK);
        assert_eq!(resolve_id(&manager, "not-a-scheme", false), LIGHT_FALLBACK);
    }
}
