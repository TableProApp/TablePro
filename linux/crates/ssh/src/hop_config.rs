use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use tablepro_core::SshFailure;

use crate::host_key_checking::HostKeyChecking;
use crate::route::JumpHop;

/// What OpenSSH reads after the user's file when it is given no `-F`
/// (`process_config_files` in ssh.c).
const SYSTEM_CONFIG: &str = "/etc/ssh/ssh_config";
const FILE_NAME: &str = "ssh_config";

/// The jump hosts whose own configuration would trust a host key the
/// user never saw, which the destination's `StrictHostKeyChecking=ask`
/// on the master's command line does not reach.
pub(crate) fn hosts_to_pin(hops: &[JumpHop]) -> Vec<&str> {
    let mut hosts: Vec<&str> = hops
        .iter()
        .filter(|hop| matches!(hop.host_keys, Some(HostKeyChecking::AcceptNew | HostKeyChecking::No)))
        .map(|hop| hop.destination.host())
        .collect();
    hosts.sort_unstable();
    hosts.dedup();
    hosts
}

/// An ssh_config that asks before trusting the key of each host in
/// `hosts`, then reads what ssh would have read without it.
///
/// ssh.c runs a jump host through a second ssh that gets only `-l`,
/// `-p`, `-J` and `-F` from the master's command line, so the master's
/// `-F` is the only way to reach it. The first value ssh_config gives
/// wins, so the pins come first. `base` is the file the master would
/// otherwise be given with `-F`.
pub(crate) fn render(hosts: &[impl AsRef<str>], base: Option<&Path>) -> Result<Vec<u8>, SshFailure> {
    render_over(hosts, base, Path::new(SYSTEM_CONFIG))
}

/// OpenSSH holds every `Include` to an owner check that it skips for
/// the `-F` file and the system file. In a Flatpak sandbox root's files
/// belong to nobody, so those two are copied in rather than included.
/// The user's file gets the same check either way.
fn render_over(hosts: &[impl AsRef<str>], base: Option<&Path>, system_config: &Path) -> Result<Vec<u8>, SshFailure> {
    let mut text = Vec::new();
    for host in hosts {
        let host = host.as_ref();
        text.extend_from_slice(format!("Host {host}\n    StrictHostKeyChecking ask\n").as_bytes());
    }
    text.extend_from_slice(b"Match all\n");
    match base {
        Some(base) => {
            let contents = std::fs::read(base).map_err(|error| SshFailure::ConfigRejected {
                detail: format!("{}: {error}", base.display()),
            })?;
            text.extend_from_slice(&contents);
        }
        None => {
            text.extend_from_slice(b"Include ~/.ssh/config\n");
            // ssh skips a system file it cannot open, so this does too.
            match std::fs::read(system_config) {
                Ok(contents) => text.extend_from_slice(&contents),
                Err(error) => tracing::debug!(%error, "the system ssh_config could not be read"),
            }
        }
    }
    Ok(text)
}

/// Writes the file into the master's private directory.
///
/// OpenSSH pastes the path into the `sh -c` line it builds for each hop
/// and expands `%` tokens in it first, so a path that is anything other
/// than one plain shell word is refused rather than run.
pub(crate) fn write(master_dir: &Path, contents: &[u8]) -> Result<PathBuf, SshFailure> {
    let path = master_dir.join(FILE_NAME);
    let unsafe_dir = |detail: String| SshFailure::RuntimeDirUnsafe {
        path: path.clone(),
        detail,
    };
    if !plain_shell_word(&path) {
        return Err(unsafe_dir(
            "a jump host's ssh cannot be given a path with spaces or shell characters".to_owned(),
        ));
    }
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .and_then(|mut file| file.write_all(contents))
        .map_err(|error| unsafe_dir(error.to_string()))?;
    Ok(path)
}

fn plain_shell_word(path: &Path) -> bool {
    path.as_os_str()
        .as_bytes()
        .iter()
        .all(|byte| byte.is_ascii_alphanumeric() || b"/._-+@:=,".contains(byte))
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;
    use crate::SshDestination;

    fn hop(host: &str, host_keys: Option<HostKeyChecking>) -> JumpHop {
        JumpHop {
            destination: SshDestination::new(host, None, None).unwrap(),
            host_keys,
        }
    }

    #[test]
    fn only_hosts_whose_configuration_skips_the_dialog_are_pinned() {
        let hops = [
            hop("j3", Some(HostKeyChecking::No)),
            hop("j2", Some(HostKeyChecking::Yes)),
            hop("j1", Some(HostKeyChecking::AcceptNew)),
            hop("j0", Some(HostKeyChecking::Ask)),
            hop("unknown", None),
            hop("j1", Some(HostKeyChecking::AcceptNew)),
        ];

        assert_eq!(hosts_to_pin(&hops), ["j1", "j3"]);
    }

    fn file(dir: &Path, name: &str, contents: &str, mode: u32) -> PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, contents).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).unwrap();
        path
    }

    #[test]
    fn the_pins_come_before_what_ssh_would_have_read() {
        let dir = tempfile::tempdir().unwrap();
        let system = file(dir.path(), "system", "SendEnv LANG\n", 0o644);
        let base = file(dir.path(), "base", "Host *\n  User ops\n", 0o644);

        assert_eq!(
            String::from_utf8(render_over(&["j1", "fd00::1"], None, &system).unwrap()).unwrap(),
            "Host j1\n    StrictHostKeyChecking ask\nHost fd00::1\n    StrictHostKeyChecking ask\nMatch all\n\
             Include ~/.ssh/config\nSendEnv LANG\n"
        );
        assert_eq!(
            String::from_utf8(render_over(&["j1"], Some(&base), &system).unwrap()).unwrap(),
            "Host j1\n    StrictHostKeyChecking ask\nMatch all\nHost *\n  User ops\n"
        );
        assert_eq!(
            String::from_utf8(render_over(&["j1"], None, &dir.path().join("missing")).unwrap()).unwrap(),
            "Host j1\n    StrictHostKeyChecking ask\nMatch all\nInclude ~/.ssh/config\n"
        );
    }

    #[test]
    fn a_base_file_ssh_could_not_open_is_refused() {
        let dir = tempfile::tempdir().unwrap();

        assert!(matches!(
            render(&["j1"], Some(&dir.path().join("missing"))),
            Err(SshFailure::ConfigRejected { .. })
        ));
    }

    /// A system file anyone can write fails the owner check the way
    /// root's file does in a Flatpak sandbox, where it belongs to nobody.
    /// ssh reads it on its own all the same, so the pinned file has to as
    /// well.
    #[test]
    fn ssh_reads_the_pinned_file_over_a_system_file_it_would_not_include() {
        let dir = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        let system = file(
            dir.path(),
            "system",
            "Host *\n    StrictHostKeyChecking accept-new\n    Port 2299\n",
            0o666,
        );
        let master_dir = dir.path().join("master");
        std::fs::create_dir(&master_dir).unwrap();
        let pinned = write(&master_dir, &render_over(&["j1"], None, &system).unwrap()).unwrap();

        let resolve = |host: &str| {
            let output = std::process::Command::new("ssh")
                .arg("-G")
                .arg("-F")
                .arg(&pinned)
                .arg(host)
                .env("HOME", home.path())
                .output()
                .unwrap();
            assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
            String::from_utf8(output.stdout).unwrap()
        };

        let jump = resolve("j1");
        let other = resolve("other");
        assert!(jump.lines().any(|line| line == "stricthostkeychecking ask"), "{jump}");
        assert!(jump.lines().any(|line| line == "port 2299"), "{jump}");
        assert!(
            other.lines().any(|line| line == "stricthostkeychecking accept-new"),
            "{other}"
        );
    }

    #[test]
    fn the_file_is_private_and_its_path_one_shell_word() {
        let dir = tempfile::tempdir().unwrap();

        let path = write(dir.path(), b"Match all\n").unwrap();

        assert_eq!(std::fs::read_to_string(&path).unwrap(), "Match all\n");
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        let spaced = dir.path().join("with space");
        std::fs::create_dir(&spaced).unwrap();
        assert!(matches!(
            write(&spaced, b"Match all\n"),
            Err(SshFailure::RuntimeDirUnsafe { .. })
        ));
        assert!(!plain_shell_word(Path::new("/run/user/1000/%d")));
        assert!(!plain_shell_word(Path::new("/run/user/1000/$(id)")));
        assert!(plain_shell_word(Path::new(
            "/run/user/1000/app/app.tablepro.TablePro/ssh/0123/89ab/ssh_config"
        )));
    }
}
