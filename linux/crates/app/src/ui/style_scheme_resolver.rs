use gtk4::prelude::*;
use sourceview5::prelude::*;

const LIGHT_FALLBACK: &str = "Adwaita";
const DARK_FALLBACK: &str = "Adwaita-dark";

/// GtkSourceView ships light and dark schemes as separate ids linked by
/// `dark-variant` and `light-variant` metadata. The user picks one id;
/// this follows the link so the editor tracks the desktop theme instead
/// of staying light on a dark desktop.
pub(crate) fn resolve_id(manager: &sourceview5::StyleSchemeManager, preferred: &str, dark: bool) -> String {
    let fallback = if dark { DARK_FALLBACK } else { LIGHT_FALLBACK };
    let Some(scheme) = manager.scheme(preferred) else {
        return fallback.to_owned();
    };
    let key = if dark { "dark-variant" } else { "light-variant" };
    match scheme.metadata(key) {
        Some(variant) if manager.scheme(&variant).is_some() => variant.into(),
        _ => preferred.to_owned(),
    }
}

pub(crate) fn apply(view: &sourceview5::View, preferred: &str) {
    let manager = sourceview5::StyleSchemeManager::default();
    let dark = libadwaita::StyleManager::default().is_dark();
    let id = resolve_id(&manager, preferred, dark);
    let Some(scheme) = manager.scheme(&id) else {
        return;
    };
    if let Ok(buffer) = view.buffer().downcast::<sourceview5::Buffer>() {
        buffer.set_style_scheme(Some(&scheme));
    }
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
    fn unknown_scheme_falls_back_to_the_adwaita_pair() {
        let manager = sourceview5::StyleSchemeManager::default();

        assert_eq!(resolve_id(&manager, "not-a-scheme", true), DARK_FALLBACK);
        assert_eq!(resolve_id(&manager, "not-a-scheme", false), LIGHT_FALLBACK);
    }
}
