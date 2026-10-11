/// The colour tags a connection may carry. The set is closed on
/// purpose: a free-form colour string would be untrusted text reaching
/// a CSS class name, and a palette keeps every connection list legible
/// against both the light and the dark stylesheet.
pub const CONNECTION_COLORS: &[&str] = &["blue", "teal", "green", "yellow", "orange", "red", "purple", "brown"];

/// Accept a colour tag from a file, a bundle or the picker. Returns
/// `None` for anything outside the palette, so an unknown value reads
/// as "no colour" rather than failing the whole load.
pub fn connection_color(name: &str) -> Option<&'static str> {
    let trimmed = name.trim().to_ascii_lowercase();
    CONNECTION_COLORS.iter().copied().find(|known| *known == trimmed)
}

/// CSS class for a palette entry, paired with `.tp-color-swatch` in the
/// application stylesheet. Returning a fixed string rather than a
/// formatted one keeps untrusted text out of a CSS class name even if
/// the palette check is ever loosened.
pub fn connection_color_css_class(name: &str) -> Option<&'static str> {
    let known = connection_color(name)?;
    CONNECTION_COLOR_CLASSES
        .iter()
        .find(|(color, _)| *color == known)
        .map(|(_, class)| *class)
}

pub const CONNECTION_STRIP_CLASSES: &[&str] = &[
    "tp-strip-blue",
    "tp-strip-teal",
    "tp-strip-green",
    "tp-strip-yellow",
    "tp-strip-orange",
    "tp-strip-red",
    "tp-strip-purple",
    "tp-strip-brown",
];

/// CSS class that paints the workspace tab strip in a palette colour.
pub fn connection_strip_class(name: &str) -> Option<&'static str> {
    let known = connection_color(name)?;
    let index = CONNECTION_COLORS.iter().position(|color| *color == known)?;
    CONNECTION_STRIP_CLASSES.get(index).copied()
}

const CONNECTION_COLOR_CLASSES: &[(&str, &str)] = &[
    ("blue", "tp-color-blue"),
    ("teal", "tp-color-teal"),
    ("green", "tp-color-green"),
    ("yellow", "tp-color-yellow"),
    ("orange", "tp-color-orange"),
    ("red", "tp-color-red"),
    ("purple", "tp-color-purple"),
    ("brown", "tp-color-brown"),
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_palette_colour_has_a_strip_class() {
        assert_eq!(CONNECTION_COLORS.len(), CONNECTION_STRIP_CLASSES.len());
        for (color, class) in CONNECTION_COLORS.iter().zip(CONNECTION_STRIP_CLASSES) {
            assert_eq!(connection_strip_class(color), Some(*class));
            assert_eq!(*class, format!("tp-strip-{color}"));
        }
        assert_eq!(connection_strip_class("red; background: url(x)"), None);
    }

    #[test]
    fn the_palette_has_no_duplicates() {
        let mut sorted = CONNECTION_COLORS.to_vec();
        sorted.sort_unstable();
        let mut deduped = sorted.clone();
        deduped.dedup();
        assert_eq!(sorted, deduped);
    }

    #[test]
    fn palette_names_are_lowercase_ascii() {
        for name in CONNECTION_COLORS {
            assert!(
                name.chars().all(|c| c.is_ascii_lowercase()),
                "{name} is not lowercase ascii"
            );
        }
    }

    #[test]
    fn a_palette_name_survives_case_and_padding() {
        assert_eq!(connection_color("  Blue "), Some("blue"));
        assert_eq!(connection_color("RED"), Some("red"));
    }

    #[test]
    fn a_colour_outside_the_palette_is_rejected() {
        assert_eq!(connection_color("#ff0000"), None);
        assert_eq!(connection_color("rebeccapurple"), None);
        assert_eq!(connection_color(""), None);
        assert_eq!(connection_color("blue; background: url(x)"), None);
    }

    #[test]
    fn a_css_class_is_only_built_for_a_palette_entry() {
        assert_eq!(connection_color_css_class("green"), Some("tp-color-green"));
        assert_eq!(connection_color_css_class("chartreuse"), None);
        assert_eq!(connection_color_css_class("blue; background: url(x)"), None);
    }

    #[test]
    fn every_palette_entry_has_a_css_class() {
        for name in CONNECTION_COLORS {
            assert_eq!(
                connection_color_css_class(name),
                Some(format!("tp-color-{name}").as_str())
            );
        }
        assert_eq!(CONNECTION_COLOR_CLASSES.len(), CONNECTION_COLORS.len());
    }
}
