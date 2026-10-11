use std::ffi::OsString;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::Path;

use super::{ForwardTarget, LocalEndpoint, OpenSshAuth, OpenSshConfig, OpenSshTimeouts};

const FORCED_OPTIONS: [&str; 17] = [
    "ControlMaster=yes",
    "ControlPersist=no",
    "ForkAfterAuthentication=no",
    "StreamLocalBindMask=0177",
    "StreamLocalBindUnlink=no",
    "BatchMode=no",
    "StrictHostKeyChecking=ask",
    "VisualHostKey=no",
    "Tunnel=no",
    "ClearAllForwardings=yes",
    "ExitOnForwardFailure=yes",
    "ForwardAgent=no",
    "ForwardX11=no",
    "PermitLocalCommand=no",
    "RequestTTY=no",
    "SessionType=none",
    "GatewayPorts=no",
];

const CONTROL_HOST: &str = "tablepro";

#[derive(Debug, Clone, Copy)]
pub(crate) enum ControlOp<'a> {
    Check,
    Forward {
        listen: &'a LocalEndpoint,
        target: &'a ForwardTarget,
    },
    Cancel {
        listen: &'a LocalEndpoint,
        target: &'a ForwardTarget,
    },
    Exit,
}

pub(crate) fn master_args(config: &OpenSshConfig, control: &Path, timeouts: &OpenSshTimeouts) -> Vec<OsString> {
    let mut args: Vec<OsString> = ["-M", "-N", "-T"].into_iter().map(OsString::from).collect();
    push_option(&mut args, control_path_option(control));
    for option in FORCED_OPTIONS {
        push_option(&mut args, option.into());
    }
    push_option(
        &mut args,
        format!("ConnectTimeout={}", timeouts.connect.as_secs().max(1)).into(),
    );
    push_option(
        &mut args,
        format!("ServerAliveInterval={}", timeouts.keepalive_interval.as_secs()).into(),
    );
    push_option(
        &mut args,
        format!("ServerAliveCountMax={}", timeouts.keepalive_max).into(),
    );
    push_option(&mut args, "LogLevel=INFO".into());
    push_jump_hosts(&mut args, config);
    push_auth(&mut args, &config.auth);
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

fn push_jump_hosts(args: &mut Vec<OsString>, config: &OpenSshConfig) {
    if config.jump_hosts.is_empty() {
        return;
    }
    let hops: Vec<String> = config.jump_hosts.iter().map(ToString::to_string).collect();
    args.push("-J".into());
    args.push(hops.join(",").into());
}

fn push_auth(args: &mut Vec<OsString>, auth: &OpenSshAuth) {
    match auth {
        OpenSshAuth::Agent => {}
        OpenSshAuth::PrivateKey { path, .. } => {
            if let Some(path) = path {
                args.push("-i".into());
                args.push(path.as_os_str().to_owned());
            }
        }
        OpenSshAuth::Password { .. } => push_option(
            args,
            "PreferredAuthentications=password,keyboard-interactive,publickey".into(),
        ),
    }
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
        args.push("-L".into());
        args.push(forward_spec(listen, target));
    }
    args.push("--".into());
    args.push(CONTROL_HOST.into());
    args
}

fn forward_spec(listen: &LocalEndpoint, target: &ForwardTarget) -> OsString {
    let mut spec = match listen {
        LocalEndpoint::Unix(path) => path.as_os_str().to_owned(),
        LocalEndpoint::Tcp(address) => OsString::from(address.to_string()),
    };
    spec.push(format!(":{target}"));
    spec
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
    use std::path::PathBuf;

    use secrecy::SecretString;

    use super::*;
    use crate::openssh::SshDestination;

    fn config(port: Option<u16>, user: Option<&str>, auth: OpenSshAuth) -> OpenSshConfig {
        OpenSshConfig {
            destination: SshDestination::new("db-bastion", port, user.map(str::to_owned)).unwrap(),
            jump_hosts: Vec::new(),
            auth,
        }
    }

    fn strings(args: &[OsString]) -> Vec<&str> {
        args.iter().map(|arg| arg.to_str().unwrap()).collect()
    }

    fn master(config: &OpenSshConfig) -> Vec<OsString> {
        master_args(config, Path::new("/tmp/control"), &OpenSshTimeouts::default())
    }

    #[test]
    fn master_argv_is_exact() {
        let args = master_args(
            &config(None, None, OpenSshAuth::Agent),
            Path::new("/run/user/1000/tablepro/ssh/0123456789abcdef/89abcdef/control"),
            &OpenSshTimeouts::default(),
        );
        assert_eq!(
            strings(&args),
            [
                "-M",
                "-N",
                "-T",
                "-o",
                "ControlPath=/run/user/1000/tablepro/ssh/0123456789abcdef/89abcdef/control",
                "-o",
                "ControlMaster=yes",
                "-o",
                "ControlPersist=no",
                "-o",
                "ForkAfterAuthentication=no",
                "-o",
                "StreamLocalBindMask=0177",
                "-o",
                "StreamLocalBindUnlink=no",
                "-o",
                "BatchMode=no",
                "-o",
                "StrictHostKeyChecking=ask",
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
                "SessionType=none",
                "-o",
                "GatewayPorts=no",
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
    fn every_forced_option_precedes_the_destination_and_the_destination_follows_the_separator() {
        let mut with_everything = config(Some(2222), Some("deploy"), OpenSshAuth::Agent);
        with_everything.jump_hosts = SshDestination::parse_jump_list("ops@jump1").unwrap();
        let args = master(&with_everything);
        let args = strings(&args);
        let separator = args.iter().position(|arg| *arg == "--").unwrap();
        assert_eq!(args[separator + 1..], ["db-bastion"]);
        for option in FORCED_OPTIONS {
            let position = args.iter().position(|arg| *arg == option).unwrap();
            assert!(position < separator, "{option}");
            assert_eq!(args[position - 1], "-o");
        }
    }

    #[test]
    fn port_and_user_only_when_set() {
        let without = strings(&master(&config(None, None, OpenSshAuth::Agent))).join(" ");
        assert!(!without.contains(" -p ") && !without.contains(" -l "));
        let with = master(&config(Some(2222), Some("deploy"), OpenSshAuth::Agent));
        assert_eq!(
            strings(&with[with.len() - 6..]),
            ["-p", "2222", "-l", "deploy", "--", "db-bastion"]
        );
    }

    #[test]
    fn jump_hosts_render_one_minus_j() {
        let mut with_jumps = config(None, None, OpenSshAuth::Agent);
        with_jumps.jump_hosts = SshDestination::parse_jump_list("ops@jump1:2200,[fd00::1]").unwrap();
        let args = master(&with_jumps);
        let args = strings(&args);
        assert_eq!(args.iter().filter(|arg| **arg == "-J").count(), 1);
        let position = args.iter().position(|arg| *arg == "-J").unwrap();
        assert_eq!(args[position + 1], "ops@jump1:2200,[fd00::1]");
    }

    #[test]
    fn private_key_path_adds_minus_i() {
        let auth = OpenSshAuth::PrivateKey {
            path: Some(PathBuf::from("/home/deploy/.ssh/id_ed25519")),
            passphrase: None,
        };
        let joined = strings(&master(&config(None, None, auth))).join(" ");
        assert!(
            joined.ends_with(" -i /home/deploy/.ssh/id_ed25519 -- db-bastion"),
            "{joined}"
        );

        let without_path = OpenSshAuth::PrivateKey {
            path: None,
            passphrase: None,
        };
        assert!(!strings(&master(&config(None, None, without_path))).contains(&"-i"));
    }

    #[test]
    fn preferred_authentications_per_mode() {
        let cases = [
            (OpenSshAuth::Agent, None),
            (
                OpenSshAuth::Password {
                    password: SecretString::from("secret"),
                },
                Some("PreferredAuthentications=password,keyboard-interactive,publickey"),
            ),
        ];
        for (auth, expected) in cases {
            let args = master(&config(None, None, auth));
            let preferred = strings(&args)
                .into_iter()
                .find(|arg| arg.starts_with("PreferredAuthentications="));
            assert_eq!(preferred, expected);
        }
    }

    #[test]
    fn the_password_never_reaches_the_command_line() {
        let auth = OpenSshAuth::Password {
            password: SecretString::from("s3cret-value"),
        };
        let args = master(&config(None, Some("deploy"), auth));
        assert!(strings(&args).iter().all(|arg| !arg.contains("s3cret-value")));
    }

    #[test]
    fn control_commands_ignore_the_user_config_and_escape_percent() {
        let target = ForwardTarget::new("fd00::5", 5432).unwrap();
        let unix = LocalEndpoint::Unix(PathBuf::from("/run/user/1000/m/f1"));
        let tcp = LocalEndpoint::Tcp("127.0.0.1:40123".parse().unwrap());
        let control = Path::new("/run/user/1000/m/control%");
        let ops = [
            ControlOp::Check,
            ControlOp::Forward {
                listen: &unix,
                target: &target,
            },
            ControlOp::Cancel {
                listen: &tcp,
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
                listen: &unix,
                target: &target,
            },
        );
        assert_eq!(
            strings(&forward)[6..10],
            ["-O", "forward", "-L", "/run/user/1000/m/f1:[fd00::5]:5432"]
        );
        let cancel = control_args(
            control,
            ControlOp::Cancel {
                listen: &tcp,
                target: &target,
            },
        );
        assert_eq!(
            strings(&cancel)[6..10],
            ["-O", "cancel", "-L", "127.0.0.1:40123:[fd00::5]:5432"]
        );
        assert_eq!(strings(&control_args(control, ControlOp::Exit))[6..8], ["-O", "exit"]);
    }
}
