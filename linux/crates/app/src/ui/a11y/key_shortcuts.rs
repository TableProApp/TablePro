use gtk4 as gtk;
use gtk4::gdk;

/// The `aria-keyshortcuts` value for `triggers`: each one as modifiers
/// and a key value joined by `+`, alternatives joined by spaces.
pub(crate) fn aria_key_shortcuts(triggers: &[&str]) -> Option<String> {
    let shortcuts: Vec<String> = triggers
        .iter()
        .filter_map(|accel| gtk::accelerator_parse(*accel))
        .filter_map(|(key, modifiers)| {
            let key = key_value(key)?;
            let mut parts: Vec<&str> = [
                (gdk::ModifierType::CONTROL_MASK, "Control"),
                (gdk::ModifierType::SHIFT_MASK, "Shift"),
                (gdk::ModifierType::ALT_MASK, "Alt"),
                (gdk::ModifierType::SUPER_MASK, "Super"),
            ]
            .into_iter()
            .filter(|(mask, _)| modifiers.contains(*mask))
            .map(|(_, name)| name)
            .collect();
            parts.push(&key);
            Some(parts.join("+"))
        })
        .collect();
    (!shortcuts.is_empty()).then(|| shortcuts.join(" "))
}

/// The UI Events `key` value ARIA uses, not the GDK keysym name.
fn key_value(key: gdk::Key) -> Option<String> {
    let named = match key {
        gdk::Key::Return | gdk::Key::KP_Enter | gdk::Key::ISO_Enter => "Enter",
        gdk::Key::Page_Up => "PageUp",
        gdk::Key::Page_Down => "PageDown",
        gdk::Key::BackSpace => "Backspace",
        gdk::Key::Menu => "ContextMenu",
        gdk::Key::space => "Space",
        gdk::Key::Up => "ArrowUp",
        gdk::Key::Down => "ArrowDown",
        gdk::Key::Left => "ArrowLeft",
        gdk::Key::Right => "ArrowRight",
        gdk::Key::ISO_Left_Tab => "Tab",
        _ => "",
    };
    if !named.is_empty() {
        return Some(named.to_owned());
    }
    match key.to_unicode() {
        Some(character) if !character.is_control() => Some(character.to_uppercase().collect()),
        _ => key.name().map(|name| name.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[gtk4::test]
    fn aria_key_shortcuts_formats_modifiers_and_keys() {
        assert_eq!(
            aria_key_shortcuts(&["<Primary><Shift>t"]).as_deref(),
            Some("Control+Shift+T")
        );
        assert_eq!(
            aria_key_shortcuts(&["<Primary><Shift>z", "<Primary>y"]).as_deref(),
            Some("Control+Shift+Z Control+Y")
        );
        assert_eq!(aria_key_shortcuts(&["Page_Up"]).as_deref(), Some("PageUp"));
        assert_eq!(aria_key_shortcuts(&["<Alt>Page_Down"]).as_deref(), Some("Alt+PageDown"));
        assert_eq!(
            aria_key_shortcuts(&["<Primary>Return"]).as_deref(),
            Some("Control+Enter")
        );
        assert_eq!(aria_key_shortcuts(&["Delete", "F5"]).as_deref(), Some("Delete F5"));
        assert_eq!(aria_key_shortcuts(&["<Primary>slash"]).as_deref(), Some("Control+/"));
        assert_eq!(aria_key_shortcuts(&[]), None);
        assert_eq!(aria_key_shortcuts(&["not a key"]), None);
    }
}
