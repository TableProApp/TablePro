use libadwaita as adw;
use tablepro_core::DriverRegistry;

use super::debug_info::debug_info;
use super::runtime_versions::RuntimeVersions;
use super::third_party_licenses;
use crate::config::{self, Profile};
use crate::i18n::gettext;

const DEVELOPERS: &[&str] = &["TablePro Authors https://github.com/TableProApp/TablePro/graphs/contributors"];
const DEBUG_INFO_FILENAME: &str = "tablepro-debug-info.txt";

/// The name, icon, developer, links and license come from the metainfo
/// the GResource embeds, so the dialog and the software centre agree.
pub fn build_about_dialog(drivers: &DriverRegistry) -> adw::AboutDialog {
    let dialog = adw::AboutDialog::from_appdata(&metainfo_resource(), release_notes_version(config::profile()));
    // The metainfo gives the latest release, which a development build is
    // not: its version carries the commit.
    dialog.set_version(config::VERSION);
    dialog.set_developers(DEVELOPERS);
    // Translators: your names, one per line, as "Name <email>" or "Name https://site".
    dialog.set_translator_credits(&gettext("translator-credits"));
    dialog.set_debug_info(&debug_info(&RuntimeVersions::current(), drivers));
    dialog.set_debug_info_filename(DEBUG_INFO_FILENAME);
    match third_party_licenses::embedded_legal_sections() {
        Ok(sections) => third_party_licenses::add_legal_sections(&dialog, &sections),
        Err(error) => tracing::warn!(%error, "the About dialog lists no third-party licenses"),
    }
    dialog
}

fn metainfo_resource() -> String {
    format!("{}/metainfo.xml", config::RESOURCE_BASE_PATH)
}

/// A development version has no release of its own in the metainfo, and
/// libadwaita reports a version it cannot find as a critical.
fn release_notes_version(profile: Profile) -> Option<&'static str> {
    match profile {
        Profile::Default => Some(config::VERSION),
        Profile::Development => None,
    }
}

#[cfg(test)]
mod tests {
    use gtk4 as gtk;

    use super::*;
    use crate::application::metainfo_release::newest_release;

    fn embedded_metainfo() -> String {
        crate::register_test_resources();
        let bytes = gio::resources_lookup_data(&metainfo_resource(), gio::ResourceLookupFlags::NONE)
            .expect("the metainfo is embedded at the resource base path");
        String::from_utf8(bytes.to_vec()).expect("the metainfo is UTF-8")
    }

    /// The text between the element `open` starts and the next `close`.
    fn metainfo_text<'a>(xml: &'a str, open: &str, close: &str) -> &'a str {
        let start = xml.find(open).unwrap_or_else(|| panic!("{open} is in the metainfo"));
        let content = &xml[start..];
        let content = &content[content.find('>').expect("the element's start tag closes") + 1..];
        let end = content.find(close).unwrap_or_else(|| panic!("{close} follows {open}"));
        content[..end].trim()
    }

    #[gtk4::test]
    fn about_dialog_is_built_from_metainfo() {
        adw::init().expect("libadwaita initialises under the test backend");
        let xml = embedded_metainfo();
        let homepage = metainfo_text(&xml, "<url type=\"homepage\"", "</url>");
        let bugtracker = metainfo_text(&xml, "<url type=\"bugtracker\"", "</url>");
        let help = metainfo_text(&xml, "<url type=\"help\"", "</url>");
        let developer = metainfo_text(metainfo_text(&xml, "<developer", "</developer>"), "<name", "</name>");
        assert!(!homepage.is_empty() && !bugtracker.is_empty() && !help.is_empty() && !developer.is_empty());

        let dialog = build_about_dialog(&DriverRegistry::new());

        assert_eq!(dialog.website(), homepage);
        assert_eq!(dialog.issue_url(), bugtracker);
        assert_eq!(dialog.support_url(), help);
        assert_eq!(dialog.developer_name(), developer);
        assert_eq!(dialog.application_icon(), config::APP_ID);
        assert_eq!(dialog.version(), config::VERSION);
        assert_eq!(dialog.license_type(), gtk::License::Agpl30);
        assert_eq!(dialog.application_name(), "TablePro");
        assert_eq!(
            dialog.developers().iter().map(|name| name.as_str()).collect::<Vec<_>>(),
            DEVELOPERS
        );
        assert_eq!(dialog.debug_info_filename(), DEBUG_INFO_FILENAME);
        assert!(dialog.debug_info().contains(config::APP_ID), "{}", dialog.debug_info());
    }

    #[test]
    fn embedded_metainfo_names_the_build_app_id() {
        let xml = embedded_metainfo();

        assert_eq!(metainfo_text(&xml, "<id", "</id>"), config::APP_ID);
        assert_eq!(
            metainfo_text(&xml, "<launchable", "</launchable>"),
            format!("{}.desktop", config::APP_ID)
        );
        assert!(!xml.contains("@app-id@") && !xml.contains("@gettext-package@"), "{xml}");
        assert!(
            !xml.contains("@version@") && !xml.contains("@screenshots-base-url@"),
            "{xml}"
        );
    }

    #[test]
    fn embedded_metainfo_pins_project_links_to_the_release_tag() {
        let xml = embedded_metainfo();
        let tree = format!(
            "https://github.com/TableProApp/TablePro/blob/linux-v{}/linux",
            newest_release(&xml).expect("the metainfo lists a release")
        );

        assert_eq!(
            metainfo_text(&xml, "<url type=\"translate\"", "</url>"),
            format!("{tree}/po/README.md")
        );
        assert_eq!(
            metainfo_text(&xml, "<url type=\"contribute\"", "</url>"),
            format!("{tree}/CONTRIBUTING.md")
        );
    }

    #[test]
    fn every_metainfo_screenshot_is_a_committed_png() {
        let xml = embedded_metainfo();
        let screenshots = metainfo_text(&xml, "<screenshots", "</screenshots>");
        let mut listed: Vec<String> = screenshots
            .split("</screenshot>")
            .filter(|entry| !entry.trim().is_empty())
            .map(|entry| {
                assert!(entry.contains("<caption"), "a screenshot without a caption: {entry}");
                let url = metainfo_text(entry, "<image", "</image>");
                assert!(url.starts_with("https://"), "{url}");
                url.rsplit('/').next().unwrap_or_default().to_owned()
            })
            .collect();
        listed.sort();

        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data/screenshots");
        let mut committed: Vec<String> = std::fs::read_dir(&dir)
            .expect("data/screenshots is readable")
            .map(|entry| {
                entry
                    .expect("a readable entry")
                    .file_name()
                    .to_string_lossy()
                    .into_owned()
            })
            .collect();
        committed.sort();

        assert_eq!(listed, committed);
        assert!(!listed.is_empty());
        for name in &listed {
            let bytes = std::fs::read(dir.join(name)).expect("the screenshot is readable");
            assert!(bytes.starts_with(b"\x89PNG\r\n\x1a\n"), "{name} is not a PNG");
        }
    }

    #[test]
    fn release_notes_version_absent_in_development_profile() {
        assert_eq!(release_notes_version(Profile::Development), None);
        assert_eq!(release_notes_version(Profile::Default), Some(config::VERSION));
    }
}
