use libadwaita as adw;

/// Toast text carries file names, column names, paths and server
/// messages, which an `&` or `<` would break as markup, leaving an
/// empty toast.
pub(crate) fn plain_toast(message: &str) -> adw::Toast {
    let toast = adw::Toast::new(message);
    toast.set_use_markup(false);
    toast
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::plain_toast;

    #[gtk4::test]
    fn a_toast_shows_its_text_as_written() {
        let text = "ssh-keygen could not open /home/a&b/<known_hosts>";

        let toast = plain_toast(text);

        assert!(!toast.uses_markup());
        assert_eq!(toast.title().as_deref(), Some(text));
    }

    fn sources(dir: &Path, found: &mut Vec<(String, String)>) {
        for entry in std::fs::read_dir(dir).expect("the source directory") {
            let path = entry.expect("an entry").path();
            if path.is_dir() {
                sources(&path, found);
            } else if path.extension().is_some_and(|extension| extension == "rs") {
                let text = std::fs::read_to_string(&path).expect("a source file");
                found.push((path.display().to_string(), text));
            }
        }
    }

    /// Every toast is plain text, so a name with an `&` in it still
    /// shows.
    #[test]
    fn every_toast_is_built_as_plain_text() {
        let mut files = Vec::new();
        sources(&Path::new(env!("CARGO_MANIFEST_DIR")).join("src"), &mut files);
        let mut offenders = Vec::new();
        for (path, text) in &files {
            if path.ends_with("ui/plain_toast.rs") {
                continue;
            }
            if text.contains("adw::Toast::new(") {
                offenders.push(format!("{path}: adw::Toast::new"));
            }
            for (start, _) in text.match_indices("Toast::builder()") {
                let chain = &text[start..];
                let chain = &chain[..chain.find(".build()").unwrap_or(chain.len())];
                if !chain.contains(".use_markup(false)") {
                    offenders.push(format!("{path}: a Toast::builder() without use_markup(false)"));
                }
            }
        }
        assert!(offenders.is_empty(), "build toasts with plain_toast: {offenders:#?}");
    }
}
