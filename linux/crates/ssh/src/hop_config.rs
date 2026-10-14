use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use tablepro_core::SshFailure;

use crate::host_key_checking::HostKeyChecking;
use crate::route::JumpHop;

/// What OpenSSH reads when it is given no `-F`, in its order: the user's
/// file, then the system's (`process_config_files` in ssh.c).
const DEFAULT_CONFIG_FILES: [&str; 2] = ["~/.ssh/config", "/etc/ssh/ssh_config"];
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
/// wins, so the pins come before the includes. `base` is the file the
/// master would otherwise be given with `-F`.
pub(crate) fn render(hosts: &[&str], base: Option<&Path>) -> Result<String, SshFailure> {
    let mut text = String::new();
    for host in hosts {
        text.push_str(&format!("Host {host}\n    StrictHostKeyChecking ask\n"));
    }
    text.push_str("Match all\n");
    match base {
        Some(base) => text.push_str(&format!("Include \"{}\"\n", included(base)?)),
        None => {
            for file in DEFAULT_CONFIG_FILES {
                text.push_str(&format!("Include {file}\n"));
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
pub(crate) fn write(master_dir: &Path, contents: &str) -> Result<PathBuf, SshFailure> {
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
        .and_then(|mut file| file.write_all(contents.as_bytes()))
        .map_err(|error| unsafe_dir(error.to_string()))?;
    Ok(path)
}

fn plain_shell_word(path: &Path) -> bool {
    path.as_os_str()
        .as_bytes()
        .iter()
        .all(|byte| byte.is_ascii_alphanumeric() || b"/._-+@:=,".contains(byte))
}

/// A path an `Include` line takes in quotes. OpenSSH 9.9 and later
/// expand `%` tokens and `${}` in it and older ones do not, so a path
/// holding either cannot be written to mean the same file on both.
fn included(path: &Path) -> Result<&str, SshFailure> {
    let rejected = || SshFailure::ConfigRejected {
        detail: format!("{} cannot be included from an ssh_config file", path.display()),
    };
    let text = path.to_str().ok_or_else(rejected)?;
    if text
        .chars()
        .any(|c| c.is_control() || matches!(c, '"' | '\\' | '%' | '$'))
    {
        return Err(rejected());
    }
    Ok(text)
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

    #[test]
    fn the_pins_come_before_what_ssh_would_have_read() {
        assert_eq!(
            render(&["j1", "fd00::1"], None).unwrap(),
            "Host j1\n    StrictHostKeyChecking ask\nHost fd00::1\n    StrictHostKeyChecking ask\nMatch all\n\
             Include ~/.ssh/config\nInclude /etc/ssh/ssh_config\n"
        );
        assert_eq!(
            render(&["j1"], Some(Path::new("/tmp/test/ssh_config"))).unwrap(),
            "Host j1\n    StrictHostKeyChecking ask\nMatch all\nInclude \"/tmp/test/ssh_config\"\n"
        );
    }

    #[test]
    fn a_base_file_that_would_expand_differently_is_refused() {
        for base in ["/tmp/%d/config", "/tmp/${HOME}/config", "/tmp/a\"b"] {
            assert!(
                matches!(
                    render(&[], Some(Path::new(base))),
                    Err(SshFailure::ConfigRejected { .. })
                ),
                "{base}"
            );
        }
    }

    #[test]
    fn the_file_is_private_and_its_path_one_shell_word() {
        let dir = tempfile::tempdir().unwrap();

        let path = write(dir.path(), "Match all\n").unwrap();

        assert_eq!(std::fs::read_to_string(&path).unwrap(), "Match all\n");
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        let spaced = dir.path().join("with space");
        std::fs::create_dir(&spaced).unwrap();
        assert!(matches!(
            write(&spaced, "Match all\n"),
            Err(SshFailure::RuntimeDirUnsafe { .. })
        ));
        assert!(!plain_shell_word(Path::new("/run/user/1000/%d")));
        assert!(!plain_shell_word(Path::new("/run/user/1000/$(id)")));
        assert!(plain_shell_word(Path::new(
            "/run/user/1000/app/app.tablepro.TablePro/ssh/0123/89ab/ssh_config"
        )));
    }
}
