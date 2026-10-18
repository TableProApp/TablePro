use tablepro_core::DriverRegistry;

use super::runtime_versions::RuntimeVersions;
use crate::config::{self, Profile};

/// The Troubleshooting text of the About dialog. A user pastes it into a
/// public bug report, so it takes nothing that could hold a connection,
/// a host, a user name or a path.
pub fn debug_info(versions: &RuntimeVersions, drivers: &DriverRegistry) -> String {
    let mut drivers: Vec<_> = drivers
        .iter()
        .map(|driver| (driver.id(), driver.display_name()))
        .collect();
    // The registry is a hash map; a report reads the same each time.
    drivers.sort_unstable();

    let mut lines = vec![
        format!("TablePro {}", config::VERSION),
        format!("Application ID: {}", config::APP_ID),
        format!("Profile: {}", profile_name(config::profile())),
        String::new(),
        format!("GTK: {}", dotted(versions.gtk)),
        format!("libadwaita: {}", dotted(versions.adwaita)),
        format!("GtkSourceView: {}", dotted(versions.sourceview)),
        format!("Sandbox: {}", if versions.flatpak { "Flatpak" } else { "none" }),
        String::new(),
        "Drivers:".to_owned(),
    ];
    lines.extend(drivers.into_iter().map(|(id, name)| format!("- {id}: {name}")));
    lines.push(String::new());
    lines.join("\n")
}

fn profile_name(profile: Profile) -> &'static str {
    match profile {
        Profile::Default => "default",
        Profile::Development => "development",
    }
}

fn dotted((major, minor, micro): (u32, u32, u32)) -> String {
    format!("{major}.{minor}.{micro}")
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;

    #[test]
    fn debug_info_lists_versions_and_drivers_only() {
        let versions = RuntimeVersions {
            gtk: (4, 22, 1),
            adwaita: (1, 9, 2),
            sourceview: (5, 18, 0),
            flatpak: true,
        };
        let mut drivers = DriverRegistry::new();
        drivers.register(Arc::new(tablepro_driver_sqlite::SqliteDriver));
        drivers.register(Arc::new(tablepro_driver_postgres::PgDriver));

        let expected = format!(
            "TablePro {version}\n\
             Application ID: {app_id}\n\
             Profile: {profile}\n\
             \n\
             GTK: 4.22.1\n\
             libadwaita: 1.9.2\n\
             GtkSourceView: 5.18.0\n\
             Sandbox: Flatpak\n\
             \n\
             Drivers:\n\
             - postgres: PostgreSQL\n\
             - sqlite: SQLite\n",
            version = config::VERSION,
            app_id = config::APP_ID,
            profile = profile_name(config::profile()),
        );
        assert_eq!(debug_info(&versions, &drivers), expected);
    }

    #[test]
    fn debug_info_says_when_there_is_no_sandbox() {
        let versions = RuntimeVersions {
            gtk: (4, 22, 0),
            adwaita: (1, 9, 0),
            sourceview: (5, 18, 0),
            flatpak: false,
        };

        let text = debug_info(&versions, &DriverRegistry::new());

        assert!(text.contains("\nSandbox: none\n"), "{text}");
        assert!(text.ends_with("Drivers:\n"), "{text}");
    }

    #[test]
    fn profile_names_match_the_meson_option() {
        assert_eq!(profile_name(Profile::Default), "default");
        assert_eq!(profile_name(Profile::Development), "development");
    }
}
