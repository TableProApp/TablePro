use gtk4 as gtk;

/// One block on the Legal page of the About dialog.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LegalSection {
    pub title: String,
    pub license_type: gtk::License,
    /// Set only for `gtk::License::Custom`: for a known type the dialog
    /// names the license and links to it.
    pub license_text: Option<String>,
}

impl LegalSection {
    /// The dialog sets a custom license as Pango markup, and a copyright
    /// line such as `Name <mail@example.org>` would blank the section.
    pub fn license_markup(&self) -> Option<glib::GString> {
        self.license_text.as_deref().map(glib::markup_escape_text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn license_markup_escapes_the_text() {
        let section = LegalSection {
            title: "a".to_owned(),
            license_type: gtk::License::Custom,
            license_text: Some("Copyright 2020 A <a@example.org> & B".to_owned()),
        };

        assert_eq!(
            section.license_markup().as_deref(),
            Some("Copyright 2020 A &lt;a@example.org&gt; &amp; B")
        );
    }

    #[test]
    fn license_markup_is_absent_without_a_text() {
        let section = LegalSection {
            title: "a".to_owned(),
            license_type: gtk::License::MitX11,
            license_text: None,
        };

        assert_eq!(section.license_markup(), None);
    }
}
