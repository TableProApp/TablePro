use std::collections::HashMap;
use std::ffi::OsString;
use std::io::Write as _;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::LazyLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use tablepro_mcp::clients::{
    Applies, CliInstall, CliUpdate, ClientCatalog, ClientConfigStatus, ClientDefinition, ClientPlatform,
    ConfigEditError, ConfigFormat, ConfigLocation, DetectRule, InstallMethod, JsonValue, PlatformSpec, ServerTarget,
    StaleReason, TemplateError, TemplateRenderer, UnsupportedReason, command_line, evaluate_status, expand_path,
    read_member, remove_member, snippet, upsert_member,
};

const PLATFORM: ClientPlatform = ClientPlatform::Linux;
const FLATPAK_INFO: &str = "/.flatpak-info";
const BACKUP_SUFFIX: &str = ".tablepro-backup";
// A client's CLI writes one entry and exits; one that waits on input
// never will.
const COMMAND_LIMIT: Duration = Duration::from_secs(30);

static CATALOG: LazyLock<Option<ClientCatalog>> = LazyLock::new(|| match ClientCatalog::bundled() {
    Ok(catalog) => Some(catalog),
    Err(error) => {
        tracing::error!(code = error.code(), %error, "the MCP client catalog does not parse");
        None
    }
});

pub fn catalog() -> Option<&'static ClientCatalog> {
    CATALOG.as_ref()
}

pub fn linux_clients() -> impl Iterator<Item = &'static ClientDefinition> {
    catalog().into_iter().flat_map(|catalog| catalog.clients_on(PLATFORM))
}

pub fn location(client: &ClientDefinition) -> Option<&'static ConfigLocation> {
    catalog().and_then(|catalog| catalog.location(client, PLATFORM))
}

fn spec(client: &ClientDefinition) -> Option<&PlatformSpec> {
    client.spec(PLATFORM)
}

fn server_name() -> &'static str {
    catalog().map_or("tablepro", |catalog| catalog.server_name.as_str())
}

// Where other apps keep their files. Inside the Flatpak the XDG
// directories are the sandbox's, so the host's come from the platform
// crate, and no host program can be found or run.
#[derive(Debug, Clone)]
pub struct ClientHost {
    pub home: PathBuf,
    pub config: PathBuf,
    pub sandboxed: bool,
    search_path: Vec<PathBuf>,
    variables: HashMap<String, String>,
    command_env: Vec<(OsString, OsString)>,
}

impl ClientHost {
    pub fn current() -> Self {
        let dirs = tablepro_linux_platform::foreign_app_dirs();
        let sandboxed = Path::new(FLATPAK_INFO).exists();
        let search_path = match sandboxed {
            true => Vec::new(),
            false => std::env::var_os("PATH")
                .map(|path| std::env::split_paths(&path).collect())
                .unwrap_or_default(),
        };
        Self {
            home: dirs.home,
            config: dirs.config,
            sandboxed,
            search_path,
            // `vars()` panics on a variable that is not UTF-8; no catalog path names one.
            variables: std::env::vars_os()
                .filter_map(|(name, value)| Some((name.into_string().ok()?, value.into_string().ok()?)))
                .collect(),
            command_env: Vec::new(),
        }
    }

    pub fn expand(&self, path: &str) -> PathBuf {
        let home = self.home.to_string_lossy();
        PathBuf::from(expand_path(path, &home, |name| match name {
            "XDG_CONFIG_HOME" => Some(self.config.to_string_lossy().into_owned()),
            "HOME" => Some(home.clone().into_owned()),
            other => self.variables.get(other).cloned(),
        }))
    }

    fn find_binary(&self, name: &str, paths: &[String]) -> Option<PathBuf> {
        paths
            .iter()
            .map(|path| self.expand(path))
            .chain(self.search_path.iter().map(|dir| dir.join(name)))
            .find(|path| is_executable(path))
    }

    fn detects(&self, rules: &[DetectRule]) -> bool {
        rules.iter().any(|rule| match rule {
            DetectRule::Binary { name, paths } => self.find_binary(name, paths).is_some(),
            DetectRule::Path(path) => self.expand(path).exists(),
            DetectRule::BundleId(_) => false,
        })
    }

    // A CLI the catalog names, found where its detect rule looks or on
    // PATH. Never inside the Flatpak, which cannot start host programs.
    fn find_cli(&self, cli: &CliInstall, spec: &PlatformSpec) -> Option<PathBuf> {
        if self.sandboxed {
            return None;
        }
        let paths = spec
            .detect
            .iter()
            .find_map(|rule| match rule {
                DetectRule::Binary { name, paths } if *name == cli.binary => Some(paths.as_slice()),
                _ => None,
            })
            .unwrap_or_default();
        self.find_binary(&cli.binary, paths)
    }
}

fn is_executable(path: &Path) -> bool {
    std::fs::metadata(path).is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

#[derive(Debug, Clone)]
enum Installer {
    File(&'static ConfigLocation),
    Cli { cli: CliInstall, binary: PathBuf },
}

fn installer(host: &ClientHost, client: &'static ClientDefinition) -> Option<Installer> {
    let spec = spec(client)?;
    let location = location(client);
    spec.install.iter().find_map(|method| match method {
        InstallMethod::File => location
            .filter(|location| location.writable && location.format != ConfigFormat::Yaml)
            .map(Installer::File),
        InstallMethod::Cli(cli) => host.find_cli(cli, spec).map(|binary| Installer::Cli {
            cli: cli.clone(),
            binary,
        }),
        InstallMethod::Deeplink(_) => None,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClientAction {
    Install,
    Update,
    Copy,
    None,
}

#[derive(Debug, Clone)]
pub struct ClientState {
    pub client: &'static ClientDefinition,
    pub detected: bool,
    pub status: ClientConfigStatus,
    pub config_path: Option<PathBuf>,
    pub action: ClientAction,
    pub removable: bool,
    // Remove goes through the client's own CLI, not a file TablePro edits.
    pub removes_with_command: bool,
}

impl ClientState {
    pub fn unsupported(&self) -> Option<UnsupportedReason> {
        spec(self.client).and_then(|spec| spec.unsupported)
    }

    pub fn applies(&self) -> Option<Applies> {
        spec(self.client).and_then(|spec| spec.applies)
    }

    // The order the page lists clients in: set up first, then found on
    // this computer, then the rest, each in catalog order.
    pub fn rank(&self) -> u8 {
        match (
            self.status.is_configured() || self.status == ClientConfigStatus::OtherScope,
            self.detected,
        ) {
            (true, _) => 0,
            (false, true) => 1,
            (false, false) => 2,
        }
    }
}

// Shadowed and Disabled have nothing an install could fix: the entry
// TablePro writes is current, and the client keeps the rest.
fn action(status: ClientConfigStatus, installer: Option<&Installer>, has_entry: bool) -> ClientAction {
    match (status, installer) {
        (_, _) if !has_entry => ClientAction::None,
        (_, _) if entry_is_current(status) => ClientAction::None,
        (ClientConfigStatus::Unreadable, Some(Installer::File(_))) | (_, None) => ClientAction::Copy,
        (ClientConfigStatus::Unknown, _) => ClientAction::Copy,
        (ClientConfigStatus::Stale(_), Some(_)) => ClientAction::Update,
        (_, Some(_)) => ClientAction::Install,
    }
}

fn entry_is_current(status: ClientConfigStatus) -> bool {
    matches!(
        status,
        ClientConfigStatus::Current | ClientConfigStatus::Disabled | ClientConfigStatus::Stale(StaleReason::Shadowed)
    )
}

// Reads every client's file. Blocking: run it off the GTK thread.
pub fn survey(host: &ClientHost, url: &str, authorization: Option<&str>) -> Vec<ClientState> {
    let target = ServerTarget::Http {
        url: url.to_owned(),
        authorization: authorization.map(str::to_owned),
    };
    linux_clients().map(|client| state(host, client, &target)).collect()
}

fn state(host: &ClientHost, client: &'static ClientDefinition, target: &ServerTarget) -> ClientState {
    let spec = spec(client);
    let location = location(client);
    let config_path = location.map(|location| host.expand(&location.path));
    let template = spec.and_then(|spec| spec.entry.as_ref());
    let status = match (template, spec.and_then(|spec| spec.unsupported)) {
        (Some(template), None) => match config_path.as_deref().map_or(ConfigText::Missing, read_config) {
            ConfigText::Unreadable => ClientConfigStatus::Unreadable,
            ConfigText::Missing => evaluate_status(None, location, server_name(), template, target, |_| true),
            ConfigText::Text(text) => evaluate_status(Some(&text), location, server_name(), template, target, |_| true),
        },
        _ => ClientConfigStatus::Unknown,
    };
    let installer = installer(host, client);
    let removable = status.is_configured()
        && match &installer {
            Some(Installer::File(_)) => true,
            Some(Installer::Cli { cli, .. }) => cli.remove.is_some(),
            None => false,
        };
    ClientState {
        client,
        detected: spec.is_some_and(|spec| host.detects(&spec.detect)),
        status,
        action: action(status, installer.as_ref(), template.is_some()),
        removes_with_command: matches!(installer, Some(Installer::Cli { .. })),
        removable,
        config_path,
    }
}

enum ConfigText {
    Missing,
    Text(String),
    Unreadable,
}

fn read_config(path: &Path) -> ConfigText {
    match std::fs::read(path) {
        Ok(bytes) => String::from_utf8(bytes).map_or(ConfigText::Unreadable, ConfigText::Text),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => ConfigText::Missing,
        Err(error) => {
            tracing::debug!(%error, path = %path.display(), "a client's config could not be read");
            ConfigText::Unreadable
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ClientSetupError {
    #[error("the client is not in the catalog")]
    UnknownClient,
    #[error("there is no way to set up this client from TablePro")]
    NoInstaller,
    #[error(transparent)]
    Template(#[from] TemplateError),
    #[error("{}: {}", .path.display(), .error.code())]
    Edit { path: PathBuf, error: ConfigEditError },
    #[error("{}: {source}", .path.display())]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("{} is not text", .0.display())]
    NotText(PathBuf),
    #[error("{} changed while it was being written", .0.display())]
    ChangedDuringWrite(PathBuf),
    #[error("{} did not hold the change after it was written", .0.display())]
    VerificationFailed(PathBuf),
    #[error("the client's command exited with {0:?}")]
    CommandFailed(Option<i32>),
    #[error("the client's command did not finish")]
    CommandTimedOut,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SetupOutcome {
    Written { path: PathBuf, backup: Option<PathBuf> },
    Unchanged,
    Ran,
}

fn client_by_id(id: &str) -> Result<&'static ClientDefinition, ClientSetupError> {
    linux_clients()
        .find(|client| client.id == id)
        .ok_or(ClientSetupError::UnknownClient)
}

fn rendered_entry(client: &ClientDefinition, target: &ServerTarget) -> Result<JsonValue, ClientSetupError> {
    let spec = spec(client).ok_or(ClientSetupError::UnknownClient)?;
    Ok(TemplateRenderer::new(server_name(), target).entry(spec)?)
}

// The setup to paste is the client's own command rather than a file.
pub fn setup_is_command(client: &ClientDefinition) -> bool {
    spec(client).is_some_and(|spec| {
        spec.install
            .iter()
            .any(|method| matches!(method, InstallMethod::Cli(_)))
    })
}

// What a user pastes: the client's own command where TablePro would run
// it, otherwise the fragment for its config file.
pub fn setup_text(id: &str, url: &str, authorization: &str) -> Result<String, ClientSetupError> {
    let client = client_by_id(id)?;
    let target = ServerTarget::Http {
        url: url.to_owned(),
        authorization: Some(authorization.to_owned()),
    };
    let entry = rendered_entry(client, &target)?;
    let cli = spec(client).and_then(|spec| {
        spec.install.iter().find_map(|method| match method {
            InstallMethod::Cli(cli) => Some(cli),
            _ => None,
        })
    });
    if let Some(cli) = cli {
        let arguments = TemplateRenderer::new(server_name(), &target).arguments(&cli.add, &entry)?;
        return Ok(command_line(&cli.binary, &arguments));
    }
    let location = location(client);
    snippet(location, server_name(), &entry).map_err(|error| ClientSetupError::Edit {
        path: location
            .map(|location| PathBuf::from(&location.path))
            .unwrap_or_default(),
        error,
    })
}

// The command Remove runs, for the confirmation to name.
pub fn remove_command(host: &ClientHost, id: &str) -> Option<String> {
    let client = client_by_id(id).ok()?;
    let Some(Installer::Cli { cli, .. }) = installer(host, client) else {
        return None;
    };
    Some(command_line(&cli.binary, &arguments_for(cli.remove.as_deref()?)))
}

fn arguments_for(template: &[String]) -> Vec<String> {
    template
        .iter()
        .map(|argument| argument.replace("{name}", server_name()))
        .collect()
}

// Install and Update. Blocking: run it off the GTK thread.
pub fn install(host: &ClientHost, id: &str, url: &str, authorization: &str) -> Result<SetupOutcome, ClientSetupError> {
    let client = client_by_id(id)?;
    let target = ServerTarget::Http {
        url: url.to_owned(),
        authorization: Some(authorization.to_owned()),
    };
    let entry = rendered_entry(client, &target)?;
    match installer(host, client).ok_or(ClientSetupError::NoInstaller)? {
        Installer::File(location) => {
            let template = spec(client)
                .and_then(|spec| spec.entry.as_ref())
                .ok_or(TemplateError::NoEntry)?;
            let path = host.expand(&location.path);
            let edit = |error| ClientSetupError::Edit {
                path: path.clone(),
                error,
            };
            update_file(
                &path,
                |text| {
                    let text = text.unwrap_or_default();
                    upsert_member(
                        location.format,
                        text,
                        &location.key_path,
                        server_name(),
                        &entry,
                        template,
                    )
                    .map_err(&edit)
                },
                |text| {
                    entry_is_current(evaluate_status(
                        Some(text),
                        Some(location),
                        server_name(),
                        template,
                        &target,
                        |_| true,
                    ))
                },
            )
        }
        Installer::Cli { cli, binary } => {
            let renderer = TemplateRenderer::new(server_name(), &target);
            let add = renderer.arguments(&cli.add, &entry)?;
            let configured = state(host, client, &target).status.is_configured();
            if configured
                && cli.update == CliUpdate::RemoveThenAdd
                && let Some(remove) = &cli.remove
            {
                // Fails when there is nothing to remove, which is fine.
                let _ = run(host, &binary, &arguments_for(remove));
            }
            run(host, &binary, &add)?;
            let path = location(client).map(|location| host.expand(&location.path));
            // The CLI writes the token into its file under the user's umask.
            if let Some(path) = &path {
                keep_private(path);
            }
            match entry_is_current(state(host, client, &target).status) {
                true => Ok(SetupOutcome::Ran),
                false => Err(ClientSetupError::VerificationFailed(path.unwrap_or_default())),
            }
        }
    }
}

// Blocking: run it off the GTK thread.
pub fn remove(host: &ClientHost, id: &str) -> Result<SetupOutcome, ClientSetupError> {
    let client = client_by_id(id)?;
    match installer(host, client).ok_or(ClientSetupError::NoInstaller)? {
        Installer::File(location) => {
            let path = host.expand(&location.path);
            let edit = |error| ClientSetupError::Edit {
                path: path.clone(),
                error,
            };
            update_file(
                &path,
                |text| match text {
                    None => Ok(String::new()),
                    Some(text) => {
                        remove_member(location.format, text, &location.key_path, server_name()).map_err(&edit)
                    }
                },
                |text| {
                    text.is_empty()
                        || read_member(location.format, text, &location.key_path, server_name())
                            .is_ok_and(|found| found.is_none())
                },
            )
        }
        Installer::Cli { cli, binary } => {
            let template = cli.remove.as_deref().ok_or(ClientSetupError::NoInstaller)?;
            run(host, &binary, &arguments_for(template))?;
            Ok(SetupOutcome::Ran)
        }
    }
}

fn keep_private(path: &Path) {
    let Ok(metadata) = std::fs::metadata(path) else {
        return;
    };
    let mode = metadata.permissions().mode();
    if mode & 0o077 == 0 {
        return;
    }
    if let Err(error) = std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode & 0o700)) {
        tracing::warn!(%error, path = %path.display(), "a client's file holding the token stays readable by others");
    }
}

// Where Install and Remove keep the file as it was: beside the file a
// link points to, since the write goes through the link.
pub fn backup_path(config: &Path) -> PathBuf {
    let target = std::fs::canonicalize(config).unwrap_or_else(|_| config.to_owned());
    sibling(&target, BACKUP_SUFFIX)
}

// Argument by argument, never through a shell.
fn run(host: &ClientHost, binary: &Path, arguments: &[String]) -> Result<(), ClientSetupError> {
    let mut child = Command::new(binary)
        .args(arguments)
        .envs(host.command_env.iter().cloned())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|source| ClientSetupError::Io {
            path: binary.to_owned(),
            source,
        })?;
    let started = Instant::now();
    loop {
        let finished = child.try_wait().map_err(|source| ClientSetupError::Io {
            path: binary.to_owned(),
            source,
        })?;
        match finished {
            Some(status) if status.success() => return Ok(()),
            Some(status) => {
                tracing::warn!(?status, binary = %binary.display(), "a client's command failed");
                return Err(ClientSetupError::CommandFailed(status.code()));
            }
            None if started.elapsed() > COMMAND_LIMIT => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(ClientSetupError::CommandTimedOut);
            }
            None => std::thread::sleep(Duration::from_millis(50)),
        }
    }
}

// Writes through a symlink to the file it names, never replacing the
// link. Re-reads before replacing and gives up if another program keeps
// changing the file; keeps the previous bytes beside it; checks the
// result before reporting success.
fn update_file(
    path: &Path,
    transform: impl Fn(Option<&str>) -> Result<String, ClientSetupError>,
    verify: impl Fn(&str) -> bool,
) -> Result<SetupOutcome, ClientSetupError> {
    let target = resolve(path)?;
    let mut before = read_bytes(&target)?;
    let mut attempts = 0;
    let (original, updated) = loop {
        let original = before.as_deref().map(|bytes| as_text(&target, bytes)).transpose()?;
        let updated = transform(original.as_deref())?;
        let now = read_bytes(&target)?;
        if now == before {
            break (original, updated);
        }
        attempts += 1;
        if attempts > 1 {
            return Err(ClientSetupError::ChangedDuringWrite(target));
        }
        before = now;
    };
    if original.as_deref() == Some(updated.as_str()) || (original.is_none() && updated.is_empty()) {
        return Ok(SetupOutcome::Unchanged);
    }
    let io = |source| ClientSetupError::Io {
        path: target.clone(),
        source,
    };
    let backup = match &before {
        Some(bytes) => {
            let backup = backup_path(&target);
            replace(&backup, bytes, 0o600).map_err(io)?;
            Some(backup)
        }
        None => None,
    };
    // A token goes into the file, so nobody but the user may read it.
    let mode = match std::fs::metadata(&target) {
        Ok(metadata) => metadata.permissions().mode() & 0o700,
        Err(_) => 0o600,
    };
    if let Some(parent) = target.parent() {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent)
            .map_err(io)?;
    }
    replace(&target, updated.as_bytes(), mode).map_err(io)?;
    let written = std::fs::read(&target).map_err(io)?;
    if !verify(&as_text(&target, &written)?) {
        return Err(ClientSetupError::VerificationFailed(target));
    }
    Ok(SetupOutcome::Written { path: target, backup })
}

fn resolve(path: &Path) -> Result<PathBuf, ClientSetupError> {
    match std::fs::canonicalize(path) {
        Ok(resolved) => Ok(resolved),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound && path.symlink_metadata().is_err() => {
            Ok(path.to_owned())
        }
        // A link to nothing: writing would create a file wherever it points.
        Err(source) => Err(ClientSetupError::Io {
            path: path.to_owned(),
            source,
        }),
    }
}

fn read_bytes(path: &Path) -> Result<Option<Vec<u8>>, ClientSetupError> {
    match std::fs::read(path) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(source) => Err(ClientSetupError::Io {
            path: path.to_owned(),
            source,
        }),
    }
}

fn as_text(path: &Path, bytes: &[u8]) -> Result<String, ClientSetupError> {
    String::from_utf8(bytes.to_vec()).map_err(|_| ClientSetupError::NotText(path.to_owned()))
}

fn sibling(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.file_name().map(OsString::from).unwrap_or_default();
    name.push(suffix);
    path.with_file_name(name)
}

// Written beside the file and renamed over it, so a reader sees the old
// bytes or the new ones, never half of either.
fn replace(path: &Path, bytes: &[u8], mode: u32) -> std::io::Result<()> {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let temporary = sibling(
        path,
        &format!(
            ".tablepro-{}-{}.tmp",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ),
    );
    let written = write_new(&temporary, bytes, mode).and_then(|()| std::fs::rename(&temporary, path));
    if written.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    written
}

fn write_new(path: &Path, bytes: &[u8], mode: u32) -> std::io::Result<()> {
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::symlink;

    use super::*;

    const URL: &str = "http://127.0.0.1:23508/mcp";
    const HEADER: &str = "Bearer tp_test";

    impl ClientHost {
        pub(crate) fn under(home: &Path) -> Self {
            Self {
                home: home.to_owned(),
                config: home.join(".config"),
                sandboxed: false,
                search_path: vec![home.join("bin")],
                variables: HashMap::new(),
                command_env: vec![("HOME".into(), home.as_os_str().to_owned())],
            }
        }
    }

    fn find(states: &[ClientState], id: &str) -> ClientState {
        states
            .iter()
            .find(|state| state.client.id == id)
            .cloned()
            .expect("a client")
    }

    fn write(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().expect("a parent")).expect("a folder");
        std::fs::write(path, text).expect("a file");
    }

    fn mode(path: &Path) -> u32 {
        std::fs::metadata(path).expect("metadata").permissions().mode() & 0o777
    }

    #[test]
    fn every_linux_client_is_surveyed_and_a_missing_file_is_not_set_up() {
        let home = tempfile::tempdir().expect("tempdir");
        let host = ClientHost::under(home.path());

        let states = survey(&host, URL, Some(HEADER));

        assert_eq!(states.len(), linux_clients().count());
        let cursor = find(&states, "cursor");
        assert_eq!(cursor.status, ClientConfigStatus::NotConfigured);
        assert_eq!(cursor.action, ClientAction::Install);
        assert_eq!(cursor.config_path, Some(home.path().join(".cursor/mcp.json")));
        let desktop = find(&states, "claude-desktop");
        assert_eq!(desktop.unsupported(), Some(UnsupportedReason::StdioOnly));
        assert_eq!(desktop.action, ClientAction::None);
        assert_eq!(find(&states, "goose").action, ClientAction::Copy);
        assert_eq!(find(&states, "opencode").action, ClientAction::Copy);
    }

    #[test]
    fn a_client_is_found_by_its_binary_or_its_folder() {
        let home = tempfile::tempdir().expect("tempdir");
        let host = ClientHost::under(home.path());
        write(&home.path().join("bin/zed"), "#!/bin/sh\n");
        std::fs::set_permissions(home.path().join("bin/zed"), std::fs::Permissions::from_mode(0o755)).expect("chmod");
        std::fs::create_dir_all(home.path().join(".lmstudio")).expect("a folder");
        write(&home.path().join("bin/cursor"), "not executable");

        let states = survey(&host, URL, None);

        assert!(find(&states, "zed").detected);
        assert!(find(&states, "lmstudio").detected);
        assert!(!find(&states, "cursor").detected);
        assert_eq!(find(&states, "zed").rank(), 1);
    }

    #[test]
    fn install_creates_a_private_file_that_reads_as_set_up() {
        let home = tempfile::tempdir().expect("tempdir");
        let host = ClientHost::under(home.path());

        let outcome = install(&host, "cursor", URL, HEADER).expect("installed");

        let path = home.path().join(".cursor/mcp.json");
        assert_eq!(
            outcome,
            SetupOutcome::Written {
                path: path.clone(),
                backup: None
            }
        );
        assert_eq!(mode(&path), 0o600);
        assert_eq!(mode(home.path().join(".cursor").as_path()), 0o700);
        let states = survey(&host, URL, Some(HEADER));
        assert_eq!(find(&states, "cursor").status, ClientConfigStatus::Current);
        assert_eq!(find(&states, "cursor").action, ClientAction::None);
        assert!(find(&states, "cursor").removable);
        assert_eq!(
            install(&host, "cursor", URL, HEADER).expect("again"),
            SetupOutcome::Unchanged
        );
    }

    #[test]
    fn install_keeps_other_servers_and_a_backup_of_the_old_file() {
        let home = tempfile::tempdir().expect("tempdir");
        let host = ClientHost::under(home.path());
        let path = home.path().join(".config/zed/settings.json");
        let original = "// mine\n{\n  \"theme\": \"x\",\n  \"context_servers\": {\n    \"other\": {}\n  }\n}\n";
        write(&path, original);
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).expect("chmod");

        let outcome = install(&host, "zed", URL, HEADER).expect("installed");

        let written = std::fs::canonicalize(&path).expect("the file");
        let backup = sibling(&written, BACKUP_SUFFIX);
        assert_eq!(
            outcome,
            SetupOutcome::Written {
                path: written,
                backup: Some(backup.clone())
            }
        );
        assert_eq!(std::fs::read_to_string(&backup).expect("the backup"), original);
        let edited = std::fs::read_to_string(&path).expect("the file");
        assert!(edited.starts_with("// mine\n{\n  \"theme\": \"x\",\n  \"context_servers\": {\n    \"other\": {},\n"));
        assert_eq!(mode(&path), 0o600, "the token is readable by others");
    }

    #[test]
    fn a_symlinked_config_is_written_through_and_stays_a_link() {
        let home = tempfile::tempdir().expect("tempdir");
        let host = ClientHost::under(home.path());
        let real = home.path().join("dotfiles/mcp.json");
        write(&real, "{}");
        std::fs::create_dir_all(home.path().join(".cursor")).expect("a folder");
        let link = home.path().join(".cursor/mcp.json");
        symlink(&real, &link).expect("a link");

        install(&host, "cursor", URL, HEADER).expect("installed");

        assert!(link.symlink_metadata().expect("the link").file_type().is_symlink());
        assert!(std::fs::read_to_string(&real).expect("the target").contains("tablepro"));
        assert!(home.path().join("dotfiles/mcp.json.tablepro-backup").exists());
    }

    #[test]
    fn the_backup_named_for_a_linked_config_is_the_one_written() {
        let home = tempfile::tempdir().expect("tempdir");
        let host = ClientHost::under(home.path());
        let real = home.path().join("dotfiles/mcp.json");
        write(&real, "{}");
        std::fs::create_dir_all(home.path().join(".cursor")).expect("a folder");
        let link = home.path().join(".cursor/mcp.json");
        symlink(&real, &link).expect("a link");

        let outcome = install(&host, "cursor", URL, HEADER).expect("installed");

        let SetupOutcome::Written {
            backup: Some(written), ..
        } = outcome
        else {
            panic!("a backup of {outcome:?}");
        };
        assert_eq!(backup_path(&link), written);
        assert_eq!(
            written,
            std::fs::canonicalize(home.path().join("dotfiles"))
                .expect("the folder")
                .join("mcp.json.tablepro-backup")
        );
    }

    #[test]
    fn an_update_keeps_the_users_own_settings_in_the_entry() {
        let home = tempfile::tempdir().expect("tempdir");
        let host = ClientHost::under(home.path());
        let path = home.path().join(".cursor/mcp.json");
        write(
            &path,
            "{\n  \"mcpServers\": {\n    \"tablepro\": {\n      \"url\": \"http://127.0.0.1:1/mcp\",\n      \
\"timeout\": 30,\n      \"headers\": {\n        \"Authorization\": \"Bearer tp_old\",\n        \
\"X-Team\": \"data\"\n      }\n    }\n  }\n}\n",
        );
        assert_eq!(
            find(&survey(&host, URL, Some(HEADER)), "cursor").action,
            ClientAction::Update
        );

        install(&host, "cursor", URL, HEADER).expect("updated");

        let edited = std::fs::read_to_string(&path).expect("the file");
        assert!(edited.contains("\"timeout\": 30"), "{edited}");
        assert!(edited.contains("\"X-Team\": \"data\""), "{edited}");
        assert!(edited.contains("\"Authorization\": \"Bearer tp_test\""), "{edited}");
        assert_eq!(
            find(&survey(&host, URL, Some(HEADER)), "cursor").status,
            ClientConfigStatus::Current
        );
    }

    #[test]
    fn an_entry_turned_off_in_the_client_offers_no_install() {
        let home = tempfile::tempdir().expect("tempdir");
        let host = ClientHost::under(home.path());
        install(&host, "kiro", URL, HEADER).expect("installed");
        let path = home.path().join(".kiro/settings/mcp.json");
        let text = std::fs::read_to_string(&path).expect("the file");
        write(&path, &text.replace("\"disabled\": false", "\"disabled\": true"));

        let kiro = find(&survey(&host, URL, Some(HEADER)), "kiro");

        assert_eq!(kiro.status, ClientConfigStatus::Disabled);
        assert_eq!(kiro.action, ClientAction::None);
        assert!(kiro.removable);
        assert_eq!(kiro.rank(), 0);
    }

    #[test]
    fn an_entry_turned_off_with_an_old_token_offers_no_update() {
        let home = tempfile::tempdir().expect("tempdir");
        let host = ClientHost::under(home.path());
        install(&host, "cline", URL, "Bearer tp_old").expect("installed");
        let path = home.path().join(".cline/data/settings/cline_mcp_settings.json");
        let text = std::fs::read_to_string(&path).expect("the file");
        write(&path, &text.replace("\"disabled\": false", "\"disabled\": true"));

        let cline = find(&survey(&host, URL, Some(HEADER)), "cline");

        assert_eq!(cline.status, ClientConfigStatus::Disabled);
        assert_eq!(cline.action, ClientAction::None);
    }

    #[test]
    fn an_update_keeps_the_tools_the_user_allowed() {
        let home = tempfile::tempdir().expect("tempdir");
        let host = ClientHost::under(home.path());
        let path = home.path().join(".copilot/mcp-config.json");
        write(
            &path,
            r#"{"mcpServers": {"tablepro": {"type": "http", "url": "http://127.0.0.1:1/mcp",
"headers": {"Authorization": "Bearer tp_old"}, "tools": ["list_connections"]}}}"#,
        );
        assert_eq!(
            find(&survey(&host, URL, Some(HEADER)), "copilot-cli").action,
            ClientAction::Update
        );

        install(&host, "copilot-cli", URL, HEADER).expect("updated");

        let written = read_member(
            ConfigFormat::Json,
            &std::fs::read_to_string(&path).expect("the file"),
            &["mcpServers".to_owned()],
            "tablepro",
        )
        .expect("readable")
        .expect("the entry");
        assert_eq!(
            written.get("tools"),
            Some(&JsonValue::Array(vec![JsonValue::String(
                "list_connections".to_owned()
            )]))
        );
        assert_eq!(written.get("url"), Some(&JsonValue::String(URL.to_owned())));
        assert_eq!(
            find(&survey(&host, URL, Some(HEADER)), "copilot-cli").status,
            ClientConfigStatus::Current
        );
    }

    #[test]
    fn an_update_replaces_a_stdio_entry_whole() {
        let home = tempfile::tempdir().expect("tempdir");
        let host = ClientHost::under(home.path());
        let path = home.path().join(".cursor/mcp.json");
        write(
            &path,
            "{\n  \"mcpServers\": {\n    \"tablepro\": {\n      \"command\": \"/opt/TablePro/tablepro-mcp\",\n      \
\"args\": [\"--verbose\"]\n    }\n  }\n}\n",
        );
        let before = find(&survey(&host, URL, Some(HEADER)), "cursor");
        assert_eq!(before.status, ClientConfigStatus::Stale(StaleReason::OtherCommand));
        assert_eq!(before.action, ClientAction::Update);

        install(&host, "cursor", URL, HEADER).expect("updated");

        let edited = std::fs::read_to_string(&path).expect("the file");
        assert!(!edited.contains("command") && !edited.contains("args"), "{edited}");
        assert_eq!(
            find(&survey(&host, URL, Some(HEADER)), "cursor").status,
            ClientConfigStatus::Current
        );
    }

    #[test]
    fn the_host_reads_an_environment_that_is_not_utf8() {
        use std::os::unix::ffi::OsStrExt as _;

        const MARKER: &str = "TABLEPRO_TEST_NOT_UTF8";
        if std::env::var_os(MARKER).is_some() {
            let host = ClientHost::current();
            assert_eq!(
                host.expand("${CODEX_HOME:-~/.codex}/config.toml"),
                PathBuf::from("/srv/codex/config.toml")
            );
            return;
        }
        let name = format!(
            "{}::the_host_reads_an_environment_that_is_not_utf8",
            module_path!().split_once("::").map_or(module_path!(), |(_, rest)| rest)
        );
        let child = Command::new(std::env::current_exe().expect("the test binary"))
            .args([name.as_str(), "--exact", "--test-threads=1"])
            .env(MARKER, std::ffi::OsStr::from_bytes(b"caf\xe9"))
            .env("CODEX_HOME", "/srv/codex")
            .output()
            .expect("the test binary runs");

        let stdout = String::from_utf8_lossy(&child.stdout);
        assert!(
            child.status.success(),
            "{stdout}{}",
            String::from_utf8_lossy(&child.stderr)
        );
        assert!(stdout.contains("1 passed"), "{stdout}");
    }

    #[test]
    fn a_project_with_an_old_claude_code_setup_shadows_the_current_one() {
        let home = tempfile::tempdir().expect("tempdir");
        let host = ClientHost::under(home.path());
        let entry = |token: &str| {
            format!(r#"{{"type": "http", "url": "{URL}", "headers": {{"Authorization": "Bearer {token}"}}}}"#)
        };
        write(
            &home.path().join(".claude.json"),
            &format!(
                r#"{{"mcpServers": {{"tablepro": {}}}, "projects": {{"/home/ana/app": {{"mcpServers": {{"tablepro": {}}}}}}}}}"#,
                entry("tp_test"),
                entry("tp_old")
            ),
        );

        let claude = find(&survey(&host, URL, Some(HEADER)), "claude-code");

        assert_eq!(claude.status, ClientConfigStatus::Stale(StaleReason::Shadowed));
        assert_eq!(
            claude.action,
            ClientAction::None,
            "Update would not reach the project's entry"
        );
    }

    #[test]
    fn a_new_token_or_port_asks_for_an_update() {
        let home = tempfile::tempdir().expect("tempdir");
        let host = ClientHost::under(home.path());
        install(&host, "codex", URL, HEADER).expect("installed");

        let token = find(&survey(&host, URL, Some("Bearer tp_new")), "codex");
        let port = find(&survey(&host, "http://127.0.0.1:40000/mcp", None), "codex");

        assert_eq!(token.action, ClientAction::Update);
        assert_eq!(port.action, ClientAction::Update);
        assert_eq!(
            find(&survey(&host, URL, None), "codex").status,
            ClientConfigStatus::Current
        );
    }

    #[test]
    fn remove_takes_only_the_tablepro_entry() {
        let home = tempfile::tempdir().expect("tempdir");
        let host = ClientHost::under(home.path());
        let path = home.path().join(".gemini/settings.json");
        write(&path, "{\n  \"mcpServers\": {\n    \"other\": {}\n  }\n}\n");
        install(&host, "gemini", URL, HEADER).expect("installed");

        remove(&host, "gemini").expect("removed");

        assert_eq!(
            std::fs::read_to_string(&path).expect("the file"),
            "{\n  \"mcpServers\": {\n    \"other\": {}\n  }\n}\n"
        );
        assert_eq!(
            find(&survey(&host, URL, None), "gemini").status,
            ClientConfigStatus::NotConfigured
        );
    }

    #[test]
    fn a_file_that_is_not_json_is_left_alone() {
        let home = tempfile::tempdir().expect("tempdir");
        let host = ClientHost::under(home.path());
        let path = home.path().join(".cursor/mcp.json");
        write(&path, "{ not json");

        let refused = install(&host, "cursor", URL, HEADER);

        assert!(matches!(refused, Err(ClientSetupError::Edit { .. })), "{refused:?}");
        assert_eq!(std::fs::read_to_string(&path).expect("the file"), "{ not json");
        assert_eq!(find(&survey(&host, URL, None), "cursor").action, ClientAction::Copy);
    }

    fn fake_claude(home: &Path) {
        let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"$HOME/argv.log\"\n\
if [ \"$2\" = add ]; then\n  header=\"${10#Authorization: }\"\n  \
printf '{\"mcpServers\": {\"tablepro\": {\"type\": \"http\", \"url\": \"%s\", \"headers\": {\"Authorization\": \"%s\"}}}}' \
\"$8\" \"$header\" > \"$HOME/.claude.json\"\n  chmod 644 \"$HOME/.claude.json\"\nfi\n";
        let path = home.join(".local/bin/claude");
        write(&path, script);
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
    }

    #[test]
    fn claude_code_is_set_up_through_its_cli_one_argument_at_a_time() {
        let home = tempfile::tempdir().expect("tempdir");
        let host = ClientHost::under(home.path());
        fake_claude(home.path());

        assert_eq!(
            install(&host, "claude-code", URL, HEADER).expect("installed"),
            SetupOutcome::Ran
        );

        let argv = std::fs::read_to_string(home.path().join("argv.log")).expect("the arguments");
        assert_eq!(
            argv,
            "mcp\nadd\n--scope\nuser\n--transport\nhttp\ntablepro\nhttp://127.0.0.1:23508/mcp\n--header\n\
Authorization: Bearer tp_test\n"
        );
        assert_eq!(
            mode(&home.path().join(".claude.json")),
            0o600,
            "the token in the CLI's file is readable by others"
        );
        let states = survey(&host, URL, Some(HEADER));
        assert_eq!(find(&states, "claude-code").status, ClientConfigStatus::Current);
        assert!(find(&states, "claude-code").removes_with_command);
        assert_eq!(
            remove_command(&host, "claude-code").as_deref(),
            Some("claude mcp remove --scope user tablepro")
        );
    }

    #[test]
    fn the_flatpak_never_runs_a_client_command() {
        let home = tempfile::tempdir().expect("tempdir");
        let mut host = ClientHost::under(home.path());
        host.sandboxed = true;
        fake_claude(home.path());

        let state = find(&survey(&host, URL, None), "claude-code");

        assert_eq!(state.action, ClientAction::Copy);
        assert!(matches!(
            install(&host, "claude-code", URL, HEADER),
            Err(ClientSetupError::NoInstaller)
        ));
        assert!(!home.path().join("argv.log").exists());
    }

    #[test]
    fn the_setup_to_copy_is_the_command_or_the_whole_fragment() {
        let claude = setup_text("claude-code", URL, HEADER).expect("a command");
        let cursor = setup_text("cursor", URL, HEADER).expect("a fragment");

        assert_eq!(
            claude,
            "claude mcp add --scope user --transport http tablepro http://127.0.0.1:23508/mcp --header \
'Authorization: Bearer tp_test'"
        );
        assert!(cursor.contains("\"mcpServers\"") && cursor.contains("\"Authorization\": \"Bearer tp_test\""));
        assert!(matches!(
            setup_text("claude-desktop", URL, HEADER),
            Err(ClientSetupError::Template(_))
        ));
    }

    #[test]
    fn host_paths_follow_xdg_and_client_variables() {
        let home = tempfile::tempdir().expect("tempdir");
        let mut host = ClientHost::under(home.path());
        host.variables.insert("CODEX_HOME".to_owned(), "/srv/codex".to_owned());
        host.variables
            .insert("XDG_CONFIG_HOME".to_owned(), "/sandbox/config".to_owned());

        assert_eq!(
            host.expand("${CODEX_HOME:-~/.codex}/config.toml"),
            PathBuf::from("/srv/codex/config.toml")
        );
        assert_eq!(
            host.expand("${XDG_CONFIG_HOME:-~/.config}/zed/settings.json"),
            home.path().join(".config/zed/settings.json")
        );
    }
}
