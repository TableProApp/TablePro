use std::path::Path;

use gtk4 as gtk;
use libadwaita as adw;

/// The toolkit libraries the process loaded, which can be newer than the
/// ones it was built against.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RuntimeVersions {
    pub gtk: (u32, u32, u32),
    pub adwaita: (u32, u32, u32),
    pub sourceview: (u32, u32, u32),
    pub flatpak: bool,
}

impl RuntimeVersions {
    /// GTK thread only, once GTK is initialised: the bindings assert both.
    pub fn current() -> Self {
        Self {
            gtk: (gtk::major_version(), gtk::minor_version(), gtk::micro_version()),
            adwaita: (adw::major_version(), adw::minor_version(), adw::micro_version()),
            sourceview: (
                sourceview5::major_version(),
                sourceview5::minor_version(),
                sourceview5::micro_version(),
            ),
            // Flatpak writes this file at the root of every sandbox.
            flatpak: Path::new("/.flatpak-info").exists(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[gtk4::test]
    fn current_versions_meet_the_platform_floor() {
        adw::init().expect("libadwaita initialises under the test backend");

        let versions = RuntimeVersions::current();

        assert!(versions.gtk >= (4, 22, 0), "{:?}", versions.gtk);
        assert!(versions.adwaita >= (1, 9, 0), "{:?}", versions.adwaita);
        assert!(versions.sourceview >= (5, 18, 0), "{:?}", versions.sourceview);
    }
}
