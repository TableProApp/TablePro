use std::path::{Path, PathBuf};

// Flatpak binds the host's first file into every sandbox at the first path, or else its second, D-Bus's older
// copy, so the host build reads them in the same order and both builds name one machine.
pub const MACHINE_ID_FILES: [&str; 2] = ["/etc/machine-id", "/var/lib/dbus/machine-id"];

#[derive(Debug, thiserror::Error)]
#[error("cannot read {}: {source}", path.display())]
pub struct MachineIdError {
    pub path: PathBuf,
    #[source]
    pub source: std::io::Error,
}

// The machine ID's text, never sent as it is: the account hashes it first (machine-id(5)). The first file's error
// is the one to fix.
pub fn read_machine_id(paths: &[&Path]) -> Result<String, MachineIdError> {
    let mut first = None;
    for path in paths {
        match std::fs::read_to_string(path) {
            Ok(text) => return Ok(text),
            Err(source) => {
                first.get_or_insert(MachineIdError {
                    path: path.to_path_buf(),
                    source,
                });
            }
        }
    }
    Err(first.unwrap_or_else(|| MachineIdError {
        path: PathBuf::new(),
        source: std::io::Error::from(std::io::ErrorKind::NotFound),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_d_bus_copy_stands_in_as_flatpak_binds_it() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let (etc, dbus) = (dir.path().join("etc-machine-id"), dir.path().join("dbus-machine-id"));
        std::fs::write(&dbus, "4c4f5e2a0b6d4f3c9e8a7b6c5d4e3f20\n").expect("the D-Bus file");

        let from_dbus = read_machine_id(&[&etc, &dbus]).expect("a machine ID");
        std::fs::write(&etc, "4c4f5e2a0b6d4f3c9e8a7b6c5d4e3f21\n").expect("the systemd file");
        let from_etc = read_machine_id(&[&etc, &dbus]).expect("a machine ID");
        let neither = read_machine_id(&[&dir.path().join("absent"), &dir.path().join("also-absent")]);

        assert_eq!(from_dbus, "4c4f5e2a0b6d4f3c9e8a7b6c5d4e3f20\n");
        assert_eq!(from_etc, "4c4f5e2a0b6d4f3c9e8a7b6c5d4e3f21\n");
        assert!(
            matches!(&neither, Err(MachineIdError { path, .. }) if path.ends_with("absent")),
            "{neither:?}"
        );
    }
}
