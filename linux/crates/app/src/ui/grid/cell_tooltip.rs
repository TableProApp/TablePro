/// Shorter text fits a typical 200 px column, so its ellipsized display
/// needs no tooltip.
const TOOLTIP_MIN_CHARS: usize = 40;
/// A tooltip is a glance, not a viewer: past this the full value is a
/// menu item away.
pub(super) const TOOLTIP_MAX_CHARS: usize = 300;

/// The tooltip for a cell's text. `None` for a placeholder and for text
/// short enough to read in the cell.
pub(super) fn cell_tooltip(text: &str, truncated_bytes: usize, placeholder: bool) -> Option<String> {
    if placeholder {
        return None;
    }
    let mut chars = text.char_indices();
    if truncated_bytes == 0 && chars.nth(TOOLTIP_MIN_CHARS).is_none() {
        return None;
    }
    let cut = text.char_indices().nth(TOOLTIP_MAX_CHARS).map(|(index, _)| index);
    let mut tooltip = match cut {
        Some(end) => format!("{}…", &text[..end]),
        None => text.to_owned(),
    };
    if cut.is_some() || truncated_bytes > 0 {
        tooltip.push('\n');
        tooltip.push_str(&crate::i18n::gettext("Use Show Row as JSON to see the full value"));
    }
    Some(tooltip)
}

#[cfg(test)]
mod tests {
    use super::{TOOLTIP_MAX_CHARS, cell_tooltip};

    #[test]
    fn cell_tooltip_none_for_short_and_placeholder() {
        assert_eq!(cell_tooltip("short", 0, false), None);
        assert_eq!(cell_tooltip(&"x".repeat(40), 0, false), None);
        assert_eq!(cell_tooltip(&"x".repeat(500), 0, true), None, "a placeholder");
        assert_eq!(
            cell_tooltip(&"x".repeat(41), 0, false).as_deref(),
            Some("x".repeat(41).as_str())
        );
    }

    #[test]
    fn cell_tooltip_capped_at_300_chars_with_hint() {
        let tooltip = cell_tooltip(&"é".repeat(1_000), 0, false).expect("a tooltip");
        let (head, hint) = tooltip.split_once('\n').expect("a hint line");

        assert_eq!(head.chars().count(), TOOLTIP_MAX_CHARS + 1);
        assert!(head.ends_with('…'));
        assert!(hint.contains("Show Row as JSON"), "{hint}");
    }

    #[test]
    fn a_cut_cell_says_so_even_when_its_text_is_short() {
        let tooltip = cell_tooltip("head", 12, false).expect("a tooltip");

        assert!(tooltip.starts_with("head\n"), "{tooltip}");
    }
}
