use gtk4::prelude::*;
use sourceview5::prelude::*;

const LIGHT_FALLBACK: &str = "Adwaita";
const DARK_FALLBACK: &str = "Adwaita-dark";

/// The scheme the editor draws. What the user picked is drawn as it is,
/// dark or light, as the macOS theme picker does. Only the default,
/// Adwaita, follows the desktop's style through its `dark-variant` link,
/// so an install that never chose still tracks it. Following the link
/// for every pick replaced a dark scheme chosen on a light desktop with
/// its light twin.
pub(crate) fn resolve_id(manager: &sourceview5::StyleSchemeManager, preferred: &str, dark: bool) -> String {
    let fallback = if dark { DARK_FALLBACK } else { LIGHT_FALLBACK };
    let Some(scheme) = manager.scheme(preferred) else {
        return fallback.to_owned();
    };
    if preferred != LIGHT_FALLBACK {
        return preferred.to_owned();
    }
    match scheme.metadata("dark-variant").filter(|_| dark) {
        Some(variant) if manager.scheme(&variant).is_some() => variant.into(),
        _ => preferred.to_owned(),
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

/// The scheme `preferred` names, in the variant for the current style.
pub(crate) fn scheme(preferred: &str) -> Option<sourceview5::StyleScheme> {
    let manager = sourceview5::StyleSchemeManager::default();
    let dark = libadwaita::StyleManager::default().is_dark();
    manager.scheme(&resolve_id(&manager, preferred, dark))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[gtk4::test]
    fn resolve_dark_variant() {
        let manager = sourceview5::StyleSchemeManager::default();

        let dark = resolve_id(&manager, LIGHT_FALLBACK, true);
        let light = resolve_id(&manager, LIGHT_FALLBACK, false);

        assert_eq!(dark, DARK_FALLBACK);
        assert_eq!(light, LIGHT_FALLBACK);
    }

    #[gtk4::test]
    fn a_picked_scheme_is_drawn_as_picked_whatever_the_desktop() {
        let manager = sourceview5::StyleSchemeManager::default();

        assert_eq!(resolve_id(&manager, DARK_FALLBACK, false), DARK_FALLBACK);
        assert_eq!(resolve_id(&manager, DARK_FALLBACK, true), DARK_FALLBACK);
    }

    #[gtk4::test]
    fn unknown_scheme_falls_back_to_the_adwaita_pair() {
        let manager = sourceview5::StyleSchemeManager::default();

        assert_eq!(resolve_id(&manager, "not-a-scheme", true), DARK_FALLBACK);
        assert_eq!(resolve_id(&manager, "not-a-scheme", false), LIGHT_FALLBACK);
    }
}
