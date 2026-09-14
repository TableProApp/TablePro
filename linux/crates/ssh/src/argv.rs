use std::ffi::OsString;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::Path;

use tablepro_core::{LivenessPolicy, NetworkEndpoint};

use crate::{SshAuth, SshConfig};

const FORCED_OPTIONS: [&str; 14] = [
    "ControlMaster=yes",
    "ControlPersist=no",
    "ForkAfterAuthentication=no",
    "StreamLocalBindMask=0177",
    "BatchMode=no",
    "VisualHostKey=no",
    "Tunnel=no",
    "ClearAllForwardings=yes",
    "ExitOnForwardFailure=yes",
    "ForwardAgent=no",
    "ForwardX11=no",
    "PermitLocalCommand=no",
    "RequestTTY=no",
    "LogLevel=INFO",
];

#[derive(Debug, Clone, Copy)]
pub(crate) enum ControlOp<'a> {
    Check,
    Forward {
        listen: &'a Path,
        target: &'a NetworkEndpoint,
    },
    Cancel {
        listen: &'a Path,
        target: &'a NetworkEndpoint,
    },
    Exit,
}

pub(crate) fn master_args(config: &SshConfig, control: &Path, liveness: &LivenessPolicy) -> Vec<OsString> {
    let mut args: Vec<OsString> = ["-M", "-N", "-T"].into_iter().map(OsString::from).collect();
    push_option(&mut args, control_path_option(control));
    for option in &FORCED_OPTIONS[..FORCED_OPTIONS.len() - 1] {
        push_option(&mut args, OsString::from(option));
    }
    push_option(
        &mut args,
        format!("ConnectTimeout={}", liveness.connect_timeout.as_secs()).into(),
    );
    push_option(
        &mut args,
        format!("ServerAliveInterval={}", liveness.ssh_keepalive_interval.as_secs()).into(),
    );
    push_option(
        &mut args,
        format!("ServerAliveCountMax={}", liveness.ssh_keepalive_max).into(),
    );
    push_option(&mut args, OsString::from("LogLevel=INFO"));

    if !config.jump_hosts.is_empty() {
        let hops: Vec<String> = config.jump_hosts.iter().map(ToString::to_string).collect();
        args.push("-J".into());
        args.push(hops.join(",").into());
    }
    match &config.auth {
        SshAuth::Agent => {}
        SshAuth::PrivateKey { path, .. } => {
            if let Some(path) = path {
                args.push("-i".into());
                args.push(path.as_os_str().to_owned());
            }
        }
        SshAuth::Password { .. } => {
            push_option(
                &mut args,
                "PreferredAuthentications=password,keyboard-interactive,publickey".into(),
            );
        }
        SshAuth::KeyboardInteractive => {
            push_option(
                &mut args,
                "PreferredAuthentications=keyboard-interactive,password,publickey".into(),
            );
        }
    }
    if let Some(port) = config.destination.port() {
        args.push("-p".into());
        args.push(port.to_string().into());
    }
    if let Some(user) = config.destination.user() {
        args.push("-l".into());
        args.push(user.into());
    }
    args.push("--".into());
    args.push(config.destination.host().into());
    args
}

pub(crate) fn control_args(control: &Path, op: ControlOp<'_>) -> Vec<OsString> {
    let mut args: Vec<OsString> = vec!["-F".into(), "none".into()];
    push_option(&mut args, control_path_option(control));
    push_option(&mut args, "LogLevel=INFO".into());
    let (name, forward) = match op {
        ControlOp::Check => ("check", None),
        ControlOp::Forward { listen, target } => ("forward", Some((listen, target))),
        ControlOp::Cancel { listen, target } => ("cancel", Some((listen, target))),
        ControlOp::Exit => ("exit", None),
    };
    args.push("-O".into());
    args.push(name.into());
    if let Some((listen, target)) = forward {
        let mut spec = listen.as_os_str().to_owned();
        spec.push(format!(":{target}"));
        args.push("-L".into());
        args.push(spec);
    }
    args.push("--".into());
    args.push("tablepro".into());
    args
}

fn push_option(args: &mut Vec<OsString>, option: OsString) {
    args.push("-o".into());
    args.push(option);
}

fn control_path_option(control: &Path) -> OsString {
    let mut bytes = b"ControlPath=".to_vec();
    for &byte in control.as_os_str().as_bytes() {
        if byte == b'%' {
            bytes.push(b'%');
        }
        bytes.push(byte);
    }
    OsString::from_vec(bytes)
}

#[cfg(test)]
mod tests {
    use std::ffi::OsStr;
    use std::path::PathBuf;

    use secrecy::SecretString;

    use super::*;
    use crate::SshDestination;

    fn config(port: Option<u16>, user: Option<&str>, auth: SshAuth) -> SshConfig {
        SshConfig {
            destination: SshDestination::new("db-bastion", port, user.map(str::to_owned)).unwrap(),
            jump_hosts: Vec::new(),
            auth,
        }
    }

    fn strings(args: &[OsString]) -> Vec<&str> {
        args.iter().map(|arg| arg.to_str().unwrap()).collect()
    }

    #[test]
    fn master_argv_is_exact() {
        let args = master_args(
            &config(None, None, SshAuth::Agent),
            Path::new("/run/user/1000/app/ssh/0123456789abcdef/89abcdef/control"),
            &LivenessPolicy::DESKTOP,
        );
        assert_eq!(
            strings(&args),
            [
                "-M",
                "-N",
                "-T",
                "-o",
                "ControlPath=/run/user/1000/app/ssh/0123456789abcdef/89abcdef/control",
                "-o",
                "ControlMaster=yes",
                "-o",
                "ControlPersist=no",
                "-o",
                "ForkAfterAuthentication=no",
                "-o",
                "StreamLocalBindMask=0177",
                "-o",
                "BatchMode=no",
                "-o",
                "VisualHostKey=no",
                "-o",
                "Tunnel=no",
                "-o",
                "ClearAllForwardings=yes",
                "-o",
                "ExitOnForwardFailure=yes",
                "-o",
                "ForwardAgent=no",
                "-o",
                "ForwardX11=no",
                "-o",
                "PermitLocalCommand=no",
                "-o",
                "RequestTTY=no",
                "-o",
                "ConnectTimeout=10",
                "-o",
                "ServerAliveInterval=15",
                "-o",
                "ServerAliveCountMax=3",
                "-o",
                "LogLevel=INFO",
                "--",
                "db-bastion",
            ]
        );
    }

    #[test]
    fn port_and_user_only_when_set() {
        let control = Path::new("/tmp/control");
        let without = strings(&master_args(
            &config(None, None, SshAuth::Agent),
            control,
            &LivenessPolicy::DESKTOP,
        ))
        .join(" ");
        assert!(!without.contains(" -p ") && !without.contains(" -l "));
        let with = master_args(
            &config(Some(2222), Some("deploy"), SshAuth::Agent),
            control,
            &LivenessPolicy::DESKTOP,
        );
        assert_eq!(
            strings(&with[with.len() - 6..]),
            ["-p", "2222", "-l", "deploy", "--", "db-bastion"]
        );
    }

    #[test]
    fn jump_hosts_render_one_minus_j() {
        let mut with_jumps = config(None, None, SshAuth::Agent);
        with_jumps.jump_hosts = SshDestination::parse_jump_list("ops@jump1:2200,[fd00::1]").unwrap();
        let args = master_args(&with_jumps, Path::new("/tmp/control"), &LivenessPolicy::DESKTOP);
        let args = strings(&args);
        assert_eq!(args.iter().filter(|arg| **arg == "-J").count(), 1);
        let position = args.iter().position(|arg| *arg == "-J").unwrap();
        assert_eq!(args[position + 1], "ops@jump1:2200,[fd00::1]");
    }

    #[test]
    fn private_key_path_adds_minus_i() {
        let auth = SshAuth::PrivateKey {
            path: Some(PathBuf::from("/home/deploy/.ssh/id_ed25519")),
            passphrase: None,
        };
        let args = master_args(
            &config(None, None, auth),
            Path::new("/tmp/control"),
            &LivenessPolicy::DESKTOP,
        );
        let joined = strings(&args).join(" ");
        assert!(
            joined.contains(" -i /home/deploy/.ssh/id_ed25519 -- db-bastion"),
            "{joined}"
        );

        let without_path = SshAuth::PrivateKey {
            path: None,
            passphrase: None,
        };
        let args = master_args(
            &config(None, None, without_path),
            Path::new("/tmp/control"),
            &LivenessPolicy::DESKTOP,
        );
        assert!(!strings(&args).contains(&"-i"));
    }

    #[test]
    fn preferred_authentications_per_mode() {
        let cases = [
            (SshAuth::Agent, None),
            (
                SshAuth::Password {
                    password: SecretString::from("secret"),
                },
                Some("PreferredAuthentications=password,keyboard-interactive,publickey"),
            ),
            (
                SshAuth::KeyboardInteractive,
                Some("PreferredAuthentications=keyboard-interactive,password,publickey"),
            ),
        ];
        for (auth, expected) in cases {
            let args = master_args(
                &config(None, None, auth),
                Path::new("/tmp/control"),
                &LivenessPolicy::DESKTOP,
            );
            let preferred = strings(&args)
                .into_iter()
                .find(|arg| arg.starts_with("PreferredAuthentications="));
            assert_eq!(preferred, expected);
        }
    }

    #[test]
    fn control_commands_start_with_f_none() {
        let target = NetworkEndpoint::new("fd00::5", 5432).unwrap();
        let listen = PathBuf::from("/run/user/1000/m/f1");
        let control = Path::new("/run/user/1000/m/control%");
        let ops = [
            ControlOp::Check,
            ControlOp::Forward {
                listen: &listen,
                target: &target,
            },
            ControlOp::Cancel {
                listen: &listen,
                target: &target,
            },
            ControlOp::Exit,
        ];
        for op in ops {
            let args = control_args(control, op);
            let args = strings(&args);
            assert_eq!(
                args[..6],
                [
                    "-F",
                    "none",
                    "-o",
                    "ControlPath=/run/user/1000/m/control%%",
                    "-o",
                    "LogLevel=INFO"
                ]
            );
            assert_eq!(args[args.len() - 2..], ["--", "tablepro"]);
        }
        let forward = control_args(
            control,
            ControlOp::Forward {
                listen: &listen,
                target: &target,
            },
        );
        assert_eq!(
            strings(&forward)[6..10],
            ["-O", "forward", "-L", "/run/user/1000/m/f1:[fd00::5]:5432"]
        );
        assert_eq!(OsStr::new("check"), control_args(control, ControlOp::Check)[7]);
    }
}
