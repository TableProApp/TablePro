use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use secrecy::ExposeSecret;
use tablepro_cli::{Host, HostError, Places, Terminal};
use tablepro_core::credentials::SecretItem;

use super::app_files::{self, McpSettings};
use crate::credential_manager;

// The Windows app's names for where it keeps the switch and the token.
const PLACES: Places = Places {
    mcp_settings: "Settings > MCP",
    token_store: "Credential Manager",
};

#[derive(Clone)]
pub(super) struct WindowsHost {
    folder: Option<PathBuf>,
    version: String,
    settings: Arc<OnceLock<Result<McpSettings, HostError>>>,
}

impl WindowsHost {
    pub(super) fn current() -> Self {
        Self {
            folder: app_files::data_folder(|name| std::env::var_os(name), package_family()),
            version: app_files::app_version(super::app_beside().and_then(|app| product_version(&app)).as_deref()),
            settings: Arc::default(),
        }
    }

    // Read each time: the app can quit or start between the command's checks.
    fn app(&self) -> Option<u32> {
        self.folder.as_deref().and_then(app_files::holder)
    }

    fn settings(&self) -> Result<McpSettings, HostError> {
        self.settings
            .get_or_init(|| {
                let folder = self.folder.as_ref().ok_or_else(|| HostError::Settings {
                    reason: "%LOCALAPPDATA% is not set".to_owned(),
                })?;
                app_files::read_settings(folder).map_err(|error| HostError::Settings {
                    reason: error.to_string(),
                })
            })
            .clone()
    }
}

impl Host for WindowsHost {
    fn app_version(&self) -> String {
        self.version.clone()
    }

    fn app_running(&self) -> bool {
        self.app().is_some()
    }

    fn server_enabled(&self) -> Result<bool, HostError> {
        Ok(self.settings()?.enabled)
    }

    fn server_port(&self) -> Result<u16, HostError> {
        Ok(self.settings()?.port)
    }

    // The app of this data folder alone: another one, as a packaged and a development build, shares the token.
    fn verify_peer(&self, peer: SocketAddr, local: SocketAddr) -> Result<(), HostError> {
        let port = peer.port();
        let Some(app) = self.app() else {
            return Err(HostError::Unverified {
                port,
                reason: "TablePro no longer holds its data folder".to_owned(),
            });
        };
        match tablepro_net::loopback_peer_process(peer, local) {
            Ok(Some(owner)) if owner == app => Ok(()),
            Ok(_) => Err(HostError::ForeignServer { port }),
            Err(error) => Err(HostError::Unverified {
                port,
                reason: error.to_string(),
            }),
        }
    }

    // Only read: a token made here would be one the running server never accepts.
    fn token(&self) -> Result<Option<String>, HostError> {
        credential_manager::read_item(credential_manager::PREFIX, SecretItem::McpToken)
            .map(|token| token.map(|token| token.expose_secret().to_owned()))
            .map_err(|error| HostError::Keyring {
                reason: error.to_string(),
            })
    }

    fn terminal(&self) -> Terminal {
        Terminal::detect()
    }

    fn places(&self) -> Places {
        PLACES
    }
}

// None for a program run outside a package, as a development build is.
fn package_family() -> Option<String> {
    use windows_sys::Win32::Foundation::{ERROR_INSUFFICIENT_BUFFER, ERROR_SUCCESS};
    use windows_sys::Win32::Storage::Packaging::Appx::GetCurrentPackageFamilyName;

    let mut length: u32 = 0;
    // SAFETY: a null buffer of length 0 only asks for the length.
    if unsafe { GetCurrentPackageFamilyName(&mut length, std::ptr::null_mut()) } != ERROR_INSUFFICIENT_BUFFER {
        return None;
    }
    let mut name = vec![0_u16; usize::try_from(length).ok()?];
    // SAFETY: `name` holds `length` units, which the first call asked for, the NUL included.
    if unsafe { GetCurrentPackageFamilyName(&mut length, name.as_mut_ptr()) } != ERROR_SUCCESS {
        return None;
    }
    let units = name.iter().position(|unit| *unit == 0).unwrap_or(name.len());
    String::from_utf16(&name[..units]).ok()
}

// The version the app shows in Settings, from TablePro.exe's version resource.
fn product_version(app: &std::path::Path) -> Option<String> {
    use std::os::windows::ffi::OsStrExt;

    use windows_sys::Win32::Storage::FileSystem::{GetFileVersionInfoSizeW, GetFileVersionInfoW};

    let path: Vec<u16> = app.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
    let mut ignored = 0;
    // SAFETY: `path` ends with a NUL.
    let size = unsafe { GetFileVersionInfoSizeW(path.as_ptr(), &mut ignored) };
    if size == 0 {
        return None;
    }
    // Words, so the block's own structures are aligned as VerQueryValueW reads them.
    let mut block = vec![0_u32; usize::try_from(size).ok()?.div_ceil(4)];
    // SAFETY: `block` holds at least `size` bytes.
    if unsafe { GetFileVersionInfoW(path.as_ptr(), 0, size, block.as_mut_ptr().cast()) } == 0 {
        return None;
    }
    // The translation's length is in bytes, two WORDs per language; a string's is in characters.
    let (translation, bytes) = query(&block, "\\VarFileInfo\\Translation")?;
    if bytes < 4 {
        return None;
    }
    // SAFETY: VerQueryValueW points into `block` at least 4 bytes of WORDs, which `block` keeps alive.
    let [language, code_page] = unsafe { [*translation, *translation.add(1)] };
    let path = format!("\\StringFileInfo\\{language:04x}{code_page:04x}\\ProductVersion");
    let (text, characters) = query(&block, &path)?;
    // SAFETY: as above, `characters` units of `block`.
    let text = unsafe { std::slice::from_raw_parts(text, usize::try_from(characters).ok()?) };
    let units = text.iter().position(|unit| *unit == 0).unwrap_or(text.len());
    String::from_utf16(&text[..units]).ok()
}

// Where the value at `path` starts inside `block`, and its length as VerQueryValueW counts it.
fn query(block: &[u32], path: &str) -> Option<(*const u16, u32)> {
    use windows_sys::Win32::Storage::FileSystem::VerQueryValueW;

    let path: Vec<u16> = path.encode_utf16().chain(std::iter::once(0)).collect();
    let mut value: *mut core::ffi::c_void = std::ptr::null_mut();
    let mut length: u32 = 0;
    // SAFETY: `block` came from GetFileVersionInfoW; `path` ends with a NUL.
    let found = unsafe { VerQueryValueW(block.as_ptr().cast(), path.as_ptr(), &mut value, &mut length) };
    (found != 0 && !value.is_null()).then_some((value.cast_const().cast::<u16>(), length))
}

#[cfg(test)]
mod tests {
    use std::net::{Ipv4Addr, TcpListener, TcpStream};

    use super::*;

    fn holding(folder: &std::path::Path, pid: u32) -> std::fs::File {
        use std::io::Write;
        use std::os::windows::fs::OpenOptionsExt;

        let file = folder.join("runtime").join("app.lock");
        std::fs::create_dir_all(file.parent().expect("a folder")).expect("the runtime folder");
        let mut held = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .share_mode(1)
            .open(file)
            .expect("the presence file");
        write!(held, "{pid}").expect("the process id");
        held
    }

    fn host(folder: &std::path::Path) -> WindowsHost {
        WindowsHost {
            folder: Some(folder.to_path_buf()),
            version: "test".to_owned(),
            settings: Arc::default(),
        }
    }

    #[test]
    fn only_the_listener_of_the_app_holding_the_folder_is_verified() {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("a free port");
        let stream = TcpStream::connect(listener.local_addr().expect("an address")).expect("a connection");
        let (peer, local) = (
            stream.peer_addr().expect("the peer"),
            stream.local_addr().expect("the local address"),
        );
        let ours = tempfile::tempdir().expect("a folder");
        let other = tempfile::tempdir().expect("a folder");
        let _ours = holding(ours.path(), std::process::id());
        let _other = holding(other.path(), std::process::id() + 1);
        let stopped = tempfile::tempdir().expect("a folder");

        assert_eq!(host(ours.path()).verify_peer(peer, local), Ok(()));
        assert_eq!(
            host(other.path()).verify_peer(peer, local),
            Err(HostError::ForeignServer { port: peer.port() })
        );
        assert!(matches!(
            host(stopped.path()).verify_peer(peer, local),
            Err(HostError::Unverified { .. })
        ));
        assert!(host(ours.path()).app_running());
        assert!(!host(stopped.path()).app_running());
    }

    #[test]
    fn the_messages_name_the_windows_settings() {
        assert_eq!(WindowsHost::current().places().mcp_settings, "Settings > MCP");
    }
}
