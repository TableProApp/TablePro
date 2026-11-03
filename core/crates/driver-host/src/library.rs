// Loaded images stay mapped because their thread-locals and timed-out workers may outlive shutdown.

use std::ffi::{CStr, c_void};
use std::mem::ManuallyDrop;
use std::path::{Path, PathBuf};

use tablepro_driver_abi::export::{self, Driver};
use tablepro_driver_abi::ffi::{self, Bytes, Descriptor, DriverApi, ErrorBuf, HostApi, OpenFn, log_level, status};

use crate::error::PluginError;
use crate::handle::DriverHandle;

pub const HOST_ABI_MINOR: u16 = 0;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DriverIdentity {
    pub id: String,
    pub version: String,
    pub abi_major: u16,
    pub abi_minor: u16,
}

pub struct DriverLibrary {
    library: ManuallyDrop<libloading::Library>,
    path: PathBuf,
    identity: DriverIdentity,
}

impl DriverLibrary {
    // `path` is absolute. Its dependencies resolve from its own folder and the system's, never the current
    // directory or PATH.
    pub fn load(path: &Path) -> Result<Self, PluginError> {
        let library = platform_load(path)?;
        let symbol = unsafe { library.get::<*const Descriptor>(ffi::DESCRIPTOR_SYMBOL) };
        let descriptor = match symbol {
            Ok(symbol) => *symbol,
            Err(error) => {
                return Err(PluginError::NotADriver {
                    path: path.display().to_string(),
                    detail: chain(&error),
                });
            }
        };
        // Mapping can run native initializers; descriptor checks precede only the ABI entry points.
        let identity = unsafe { check_descriptor(descriptor, path) }?;
        Ok(Self {
            library: ManuallyDrop::new(library),
            path: path.to_owned(),
            identity,
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn identity(&self) -> &DriverIdentity {
        &self.identity
    }

    pub fn open(&self) -> Result<DriverHandle, PluginError> {
        let symbol = unsafe { self.library.get::<OpenFn>(ffi::OPEN_SYMBOL) };
        let open = match symbol {
            Ok(symbol) => *symbol,
            Err(error) => {
                return Err(PluginError::NotADriver {
                    path: self.path.display().to_string(),
                    detail: chain(&error),
                });
            }
        };
        open_with(&self.identity.id, |host, out, out_size, error| unsafe {
            open(host, out, out_size, error)
        })
    }
}

// A driver linked into the app: the same entry point and table a loaded library has.
pub fn open_static<D: Driver>(id: &str) -> Result<DriverHandle, PluginError> {
    open_with(id, |host, out, out_size, error| unsafe {
        export::open::<D>(host, out, out_size, error)
    })
}

fn open_with(
    id: &str,
    open: impl FnOnce(*const HostApi, *mut DriverApi, usize, *mut ErrorBuf) -> i32,
) -> Result<DriverHandle, PluginError> {
    let host = host_api();
    let mut out = std::mem::MaybeUninit::<DriverApi>::uninit();
    let mut buffer = vec![0u8; 1024];
    let mut error = ErrorBuf {
        ptr: buffer.as_mut_ptr(),
        cap: buffer.len(),
        len: 0,
    };
    let code = open(&host, out.as_mut_ptr(), size_of::<DriverApi>(), &mut error);
    let detail = String::from_utf8_lossy(&buffer[..error.len.min(buffer.len())]).into_owned();
    if code != status::OK {
        return Err(PluginError::OpenFailed {
            id: id.to_owned(),
            detail: format!("status {code}: {detail}"),
        });
    }
    let api = unsafe { out.assume_init() };
    if (api.size as usize) < size_of::<DriverApi>() || api.abi_major != ffi::ABI_MAJOR {
        return Err(PluginError::OpenFailed {
            id: id.to_owned(),
            detail: format!("the driver's table is ABI {}.{}", api.abi_major, api.abi_minor),
        });
    }
    // The successful open transfers this instance to its sole owning handle.
    Ok(unsafe { DriverHandle::from_api(api) })
}

pub fn host_api() -> HostApi {
    HostApi {
        size: size_of::<HostApi>() as u32,
        abi_major: ffi::ABI_MAJOR,
        abi_minor: HOST_ABI_MINOR,
        ctx: std::ptr::null_mut(),
        log: host_log,
    }
}

unsafe extern "C" fn host_log(_ctx: *mut c_void, level: i32, message: Bytes) {
    let _ = std::panic::catch_unwind(|| {
        let text = String::from_utf8_lossy(unsafe { message.as_slice() });
        match level {
            log_level::ERROR => tracing::error!(target: "tablepro_driver", "{text}"),
            log_level::WARN => tracing::warn!(target: "tablepro_driver", "{text}"),
            log_level::INFO => tracing::info!(target: "tablepro_driver", "{text}"),
            _ => tracing::debug!(target: "tablepro_driver", "{text}"),
        }
    });
}

/// # Safety
/// `descriptor` points at a static of at least `magic` and `size`; when both are right, at a whole descriptor
/// whose strings are NUL-terminated.
pub unsafe fn check_descriptor(descriptor: *const Descriptor, path: &Path) -> Result<DriverIdentity, PluginError> {
    let not_a_driver = |detail: String| PluginError::NotADriver {
        path: path.display().to_string(),
        detail,
    };
    if descriptor.is_null() {
        return Err(not_a_driver("its descriptor is null".to_owned()));
    }
    // Inspect the fixed header before creating a reference to the whole descriptor.
    let magic = unsafe { std::ptr::addr_of!((*descriptor).magic).read() };
    let size = unsafe { std::ptr::addr_of!((*descriptor).size).read() };
    if magic != ffi::MAGIC {
        return Err(not_a_driver(format!("its descriptor's magic is {magic:#x}")));
    }
    if (size as usize) < size_of::<Descriptor>() {
        return Err(not_a_driver("its descriptor is incomplete".to_owned()));
    }
    let descriptor = unsafe { &*descriptor };
    if descriptor.driver_id.is_null() || descriptor.driver_version.is_null() {
        return Err(not_a_driver("its descriptor is incomplete".to_owned()));
    }
    let id = unsafe { CStr::from_ptr(descriptor.driver_id) }
        .to_string_lossy()
        .into_owned();
    let version = unsafe { CStr::from_ptr(descriptor.driver_version) }
        .to_string_lossy()
        .into_owned();
    if id.is_empty() {
        return Err(not_a_driver("its descriptor names no driver".to_owned()));
    }
    if descriptor.abi_major != ffi::ABI_MAJOR {
        return Err(PluginError::AbiUnsupported {
            id,
            major: descriptor.abi_major,
            host: ffi::ABI_MAJOR,
        });
    }
    if descriptor.panic_unwind != 1 {
        return Err(PluginError::PanicAbort { id });
    }
    Ok(DriverIdentity {
        id,
        version,
        abi_major: descriptor.abi_major,
        abi_minor: descriptor.abi_minor,
    })
}

#[cfg(windows)]
fn platform_load(path: &Path) -> Result<libloading::Library, PluginError> {
    use libloading::os::windows::{LOAD_LIBRARY_SEARCH_DEFAULT_DIRS, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR, Library};

    // ERROR_BAD_EXE_FORMAT: an x64 app given an Arm64 library, or the reverse.
    const BAD_EXE_FORMAT: i32 = 193;
    let flags = LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS;
    match unsafe { Library::load_with_flags(path, flags) } {
        Ok(library) => Ok(library.into()),
        Err(error) => {
            let code = std::error::Error::source(&error)
                .and_then(|inner| inner.downcast_ref::<std::io::Error>())
                .and_then(std::io::Error::raw_os_error);
            if code == Some(BAD_EXE_FORMAT) {
                Err(PluginError::WrongArchitecture {
                    path: path.display().to_string(),
                })
            } else {
                Err(PluginError::LoadFailed {
                    path: path.display().to_string(),
                    detail: chain(&error),
                })
            }
        }
    }
}

#[cfg(unix)]
fn platform_load(path: &Path) -> Result<libloading::Library, PluginError> {
    use libloading::os::unix::{Library, RTLD_LOCAL, RTLD_NOW};

    match unsafe { Library::open(Some(path), RTLD_NOW | RTLD_LOCAL) } {
        Ok(library) => Ok(library.into()),
        Err(error) => Err(PluginError::LoadFailed {
            path: path.display().to_string(),
            detail: chain(&error),
        }),
    }
}

// libloading keeps the system's text in the error's source, not in its Display.
fn chain(error: &dyn std::error::Error) -> String {
    let mut text = error.to_string();
    let mut source = error.source();
    while let Some(inner) = source {
        text.push_str(": ");
        text.push_str(&inner.to_string());
        source = inner.source();
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    fn descriptor(magic: u32, major: u16, unwind: u8) -> Descriptor {
        Descriptor {
            magic,
            size: size_of::<Descriptor>() as u32,
            abi_major: major,
            abi_minor: 7,
            panic_unwind: unwind,
            reserved: [0; 7],
            driver_id: c"future".as_ptr(),
            driver_version: c"2.0.0".as_ptr(),
        }
    }

    fn check(descriptor: &Descriptor) -> Result<DriverIdentity, PluginError> {
        unsafe { check_descriptor(descriptor, Path::new("driver")) }
    }

    #[test]
    fn a_driver_of_this_major_is_accepted_with_its_minor() {
        let identity = check(&descriptor(ffi::MAGIC, ffi::ABI_MAJOR, 1)).unwrap();

        assert_eq!(identity.id, "future");
        assert_eq!(identity.version, "2.0.0");
        assert_eq!(identity.abi_minor, 7);
    }

    #[test]
    fn another_major_is_refused_before_any_driver_code_runs() {
        let error = check(&descriptor(ffi::MAGIC, ffi::ABI_MAJOR + 1, 1)).unwrap_err();

        assert_eq!(
            error,
            PluginError::AbiUnsupported {
                id: "future".to_owned(),
                major: 2,
                host: 1
            }
        );
        assert_eq!(error.code(), "plugin.abi_unsupported");
    }

    #[test]
    fn a_foreign_magic_is_not_a_driver() {
        let error = check(&descriptor(0x7F45_4C46, ffi::ABI_MAJOR, 1)).unwrap_err();

        assert_eq!(error.code(), "plugin.not_a_driver");
    }

    #[test]
    fn a_panic_abort_build_is_refused() {
        let error = check(&descriptor(ffi::MAGIC, ffi::ABI_MAJOR, 0)).unwrap_err();

        assert_eq!(error.code(), "plugin.panic_abort");
    }

    #[test]
    fn a_descriptor_shorter_than_its_fixed_fields_is_refused() {
        let mut short = descriptor(ffi::MAGIC, ffi::ABI_MAJOR, 1);
        short.size = 16;

        assert_eq!(check(&short).unwrap_err().code(), "plugin.not_a_driver");
    }

    #[test]
    fn a_descriptor_with_only_its_header_is_refused() {
        #[repr(C)]
        struct Header {
            magic: u32,
            size: u32,
        }
        let header = Header {
            magic: ffi::MAGIC,
            size: size_of::<Header>() as u32,
        };
        let pointer = std::ptr::from_ref(&header).cast::<Descriptor>();
        let error = unsafe { check_descriptor(pointer, Path::new("driver")) }.unwrap_err();

        assert_eq!(error.code(), "plugin.not_a_driver");
    }

    #[test]
    fn a_file_that_is_no_library_does_not_load() {
        let folder = tempfile::tempdir().unwrap();
        let path = folder.path().join(format!(
            "{}text{}",
            std::env::consts::DLL_PREFIX,
            std::env::consts::DLL_SUFFIX
        ));
        std::fs::write(&path, b"not a library").unwrap();

        let error = DriverLibrary::load(&path).err().unwrap();

        assert_eq!(error.code(), "plugin.load_failed");
    }
}
