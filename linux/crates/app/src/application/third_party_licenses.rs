use std::collections::{BTreeMap, BTreeSet};

use gtk4 as gtk;
use libadwaita as adw;
use serde::Deserialize;
use thiserror::Error;

use super::legal_section::LegalSection;
use crate::config;

#[derive(Debug, Error)]
pub enum ThirdPartyLicensesError {
    #[error("could not read the embedded third-party licenses: {0}")]
    Lookup(#[source] glib::Error),
    #[error("could not parse the embedded third-party licenses: {0}")]
    Parse(#[source] serde_json::Error),
}

/// The shape `build-aux/about/third-party.json.hbs` writes.
#[derive(Deserialize)]
struct Notices {
    licenses: Vec<LicenseRecord>,
}

#[derive(Deserialize)]
struct LicenseRecord {
    id: String,
    text: String,
    used_by: Vec<UsedBy>,
}

#[derive(Deserialize)]
struct UsedBy {
    #[serde(rename = "crate")]
    krate: CrateRecord,
}

#[derive(Deserialize)]
struct CrateRecord {
    name: String,
}

#[derive(Default)]
struct LicenseGroup {
    crates: BTreeSet<String>,
    texts: Vec<String>,
}

pub fn resource_path() -> String {
    format!("{}/licenses/third-party.json", config::RESOURCE_BASE_PATH)
}

pub fn embedded_legal_sections() -> Result<Vec<LegalSection>, ThirdPartyLicensesError> {
    let json = gio::resources_lookup_data(&resource_path(), gio::ResourceLookupFlags::NONE)
        .map_err(ThirdPartyLicensesError::Lookup)?;
    legal_sections(&json)
}

/// One section per license, titled with the crates under it.
pub fn legal_sections(json: &[u8]) -> Result<Vec<LegalSection>, ThirdPartyLicensesError> {
    let notices: Notices = serde_json::from_slice(json).map_err(ThirdPartyLicensesError::Parse)?;
    // cargo-about gives each distinct text of a license its own entry,
    // since the copyright lines differ from crate to crate.
    let mut groups: BTreeMap<String, LicenseGroup> = BTreeMap::new();
    for record in notices.licenses {
        let group = groups.entry(record.id).or_default();
        group
            .crates
            .extend(record.used_by.into_iter().map(|used| used.krate.name));
        if !group.texts.contains(&record.text) {
            group.texts.push(record.text);
        }
    }
    Ok(groups
        .into_iter()
        .map(|(id, group)| {
            let license_type = gtk_license(&id);
            LegalSection {
                title: group.crates.into_iter().collect::<Vec<_>>().join(", "),
                license_type,
                license_text: (license_type == gtk::License::Custom).then(|| group.texts.join("\n\n")),
            }
        })
        .collect())
}

/// AdwAboutDialog cannot list its sections back, so the number applied
/// is what a caller can check.
pub fn add_legal_sections(dialog: &adw::AboutDialog, sections: &[LegalSection]) -> usize {
    for section in sections {
        dialog.add_legal_section(
            &section.title,
            None,
            section.license_type,
            section.license_markup().as_deref(),
        );
    }
    sections.len()
}

/// The licenses GTK can name itself. Any other is shown as its text.
fn gtk_license(spdx_id: &str) -> gtk::License {
    match spdx_id {
        "MIT" => gtk::License::MitX11,
        "Apache-2.0" => gtk::License::Apache20,
        "BSD-2-Clause" => gtk::License::Bsd,
        "BSD-3-Clause" => gtk::License::Bsd3,
        "MPL-2.0" => gtk::License::Mpl20,
        "LGPL-2.1-or-later" => gtk::License::Lgpl21,
        "0BSD" => gtk::License::_0bsd,
        _ => gtk::License::Custom,
    }
}

#[cfg(test)]
mod tests {
    use gtk4::prelude::*;
    use libadwaita::prelude::AdwDialogExt;
    use tablepro_core::DriverRegistry;

    use super::*;
    use crate::application::about_dialog::build_about_dialog;
    use crate::test_support::{descendants, drain_main_context};

    const FIXTURE: &str = r#"{
      "licenses": [
        {
          "id": "ISC",
          "name": "ISC License",
          "text": "ISC text one",
          "used_by": [{ "crate": { "name": "untrusted", "version": "0.9.0" } }]
        },
        {
          "id": "ISC",
          "name": "ISC License",
          "text": "ISC text two",
          "used_by": [{ "crate": { "name": "aws-lc-sys", "version": "0.32.0" } }]
        },
        {
          "id": "MIT",
          "name": "MIT License",
          "text": "MIT text one",
          "used_by": [
            { "crate": { "name": "serde", "version": "1.0.0" } },
            { "crate": { "name": "anyhow", "version": "1.0.0" } }
          ]
        },
        {
          "id": "MIT",
          "name": "MIT License",
          "text": "MIT text two",
          "used_by": [
            { "crate": { "name": "windows-sys", "version": "0.52.0" } },
            { "crate": { "name": "windows-sys", "version": "0.59.0" } },
            { "crate": { "name": "serde", "version": "1.0.0" } }
          ]
        },
        {
          "id": "Apache-2.0",
          "name": "Apache License 2.0",
          "text": "Apache text",
          "used_by": [{ "crate": { "name": "fragile", "version": "2.1.0" } }]
        }
      ]
    }"#;

    #[test]
    fn spdx_maps_to_gtk_license() {
        let expected = [
            ("MIT", gtk::License::MitX11),
            ("Apache-2.0", gtk::License::Apache20),
            ("BSD-2-Clause", gtk::License::Bsd),
            ("BSD-3-Clause", gtk::License::Bsd3),
            ("MPL-2.0", gtk::License::Mpl20),
            ("LGPL-2.1-or-later", gtk::License::Lgpl21),
            ("0BSD", gtk::License::_0bsd),
            ("Unicode-3.0", gtk::License::Custom),
            ("ISC", gtk::License::Custom),
        ];
        for (spdx_id, license) in expected {
            assert_eq!(gtk_license(spdx_id), license, "{spdx_id}");
        }
    }

    #[test]
    fn legal_sections_from_fixture() {
        let sections = legal_sections(FIXTURE.as_bytes()).expect("the fixture parses");

        assert_eq!(
            sections,
            vec![
                LegalSection {
                    title: "fragile".to_owned(),
                    license_type: gtk::License::Apache20,
                    license_text: None,
                },
                LegalSection {
                    title: "aws-lc-sys, untrusted".to_owned(),
                    license_type: gtk::License::Custom,
                    license_text: Some("ISC text one\n\nISC text two".to_owned()),
                },
                LegalSection {
                    title: "anyhow, serde, windows-sys".to_owned(),
                    license_type: gtk::License::MitX11,
                    license_text: None,
                },
            ]
        );
    }

    #[test]
    fn legal_sections_rejects_malformed_json() {
        for json in [&b"{"[..], br#"{ "licenses": [{ "id": "MIT" }] }"#, b"[]"] {
            assert!(
                matches!(legal_sections(json), Err(ThirdPartyLicensesError::Parse(_))),
                "{}",
                String::from_utf8_lossy(json)
            );
        }
    }

    /// Every SPDX id in the embedded file, read without the parser under test.
    fn embedded_license_ids() -> BTreeSet<String> {
        crate::register_test_resources();
        let json = gio::resources_lookup_data(&resource_path(), gio::ResourceLookupFlags::NONE)
            .expect("the third-party licenses are embedded");
        let value: serde_json::Value = serde_json::from_slice(&json).expect("the embedded file is JSON");
        value["licenses"]
            .as_array()
            .expect("a licenses array")
            .iter()
            .map(|license| license["id"].as_str().expect("an id").to_owned())
            .collect()
    }

    /// What every label of `dialog` reads once it is shown, which is when
    /// it builds its pages.
    fn presented_labels(dialog: &adw::AboutDialog) -> Vec<String> {
        let window = adw::Window::new();
        window.present();
        dialog.present(Some(&window));
        drain_main_context();
        let labels = descendants(dialog)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Label>().ok())
            .map(|label| label.text().to_string())
            .collect();
        dialog.force_close();
        window.destroy();
        labels
    }

    #[gtk4::test]
    fn custom_license_text_shows_as_written() {
        adw::init().expect("libadwaita initialises under the test backend");
        let text = "Copyright 2020 A <a@example.org> & B";
        let dialog = adw::AboutDialog::new();
        let section = LegalSection {
            title: "example".to_owned(),
            license_type: gtk::License::Custom,
            license_text: Some(text.to_owned()),
        };

        add_legal_sections(&dialog, &[section]);

        let labels = presented_labels(&dialog);
        assert!(labels.iter().any(|label| label == "example"), "{labels:?}");
        assert!(labels.iter().any(|label| label == text), "{labels:?}");
    }

    #[gtk4::test]
    fn about_dialog_shows_every_embedded_section() {
        adw::init().expect("libadwaita initialises under the test backend");
        crate::register_test_resources();
        let sections = embedded_legal_sections().expect("the embedded licenses parse");

        let labels = presented_labels(&build_about_dialog(&DriverRegistry::new()));

        for section in &sections {
            assert!(labels.contains(&section.title), "no heading {}", section.title);
            if let Some(text) = &section.license_text {
                assert!(labels.contains(text), "no text under {}", section.title);
            }
        }
    }

    #[gtk4::test]
    fn about_dialog_applies_every_section() {
        adw::init().expect("libadwaita initialises under the test backend");
        let ids = embedded_license_ids();
        assert!(ids.contains("MIT"), "{ids:?}");

        let sections = embedded_legal_sections().expect("the embedded licenses parse");
        assert_eq!(sections.len(), ids.len());
        assert!(sections.iter().all(|section| !section.title.is_empty()));

        let dialog = adw::AboutDialog::new();
        assert_eq!(add_legal_sections(&dialog, &sections), ids.len());
    }
}
