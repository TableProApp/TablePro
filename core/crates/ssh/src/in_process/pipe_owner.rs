use std::io;
use std::os::windows::io::RawHandle;
use std::ptr;

use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, LocalFree};
use windows_sys::Win32::Security::Authorization::{GetSecurityInfo, SE_KERNEL_OBJECT};
use windows_sys::Win32::Security::{
    EqualSid, GetTokenInformation, IsWellKnownSid, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID, TOKEN_QUERY,
    TOKEN_USER, TokenUser, WinBuiltinAdministratorsSid, WinLocalSystemSid,
};
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

// The OpenSSH agent service runs as LocalSystem, whose objects the Administrators group may own;
// an agent the user runs, such as 1Password's, owns its pipe as the user.
pub(crate) fn owned_by_user_or_system(pipe: RawHandle) -> io::Result<bool> {
    let mut owner: PSID = ptr::null_mut();
    let mut descriptor: PSECURITY_DESCRIPTOR = ptr::null_mut();
    // SAFETY: `pipe` is open; `owner` points into `descriptor`, freed below.
    let status = unsafe {
        GetSecurityInfo(
            pipe,
            SE_KERNEL_OBJECT,
            OWNER_SECURITY_INFORMATION,
            &mut owner,
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            &mut descriptor,
        )
    };
    if status != 0 {
        return Err(io::Error::from_raw_os_error(status.cast_signed()));
    }
    let trusted = trusted_owner(owner);
    // SAFETY: `descriptor` came from GetSecurityInfo and is freed once.
    unsafe { LocalFree(descriptor) };
    trusted
}

fn trusted_owner(owner: PSID) -> io::Result<bool> {
    // SAFETY: `owner` is a valid SID while its descriptor lives, which outlives this call.
    let system = unsafe {
        IsWellKnownSid(owner, WinLocalSystemSid) != 0 || IsWellKnownSid(owner, WinBuiltinAdministratorsSid) != 0
    };
    if system {
        return Ok(true);
    }
    // SAFETY: both SIDs are valid for the call.
    with_user_sid(|user| unsafe { EqualSid(owner, user) } != 0)
}

fn with_user_sid<T>(use_sid: impl FnOnce(PSID) -> T) -> io::Result<T> {
    let mut token: HANDLE = ptr::null_mut();
    // SAFETY: the current process's pseudo handle needs no closing; `token` is closed below.
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let mut size = 0_u32;
    // SAFETY: a null buffer of length 0 only asks for the size.
    unsafe { GetTokenInformation(token, TokenUser, ptr::null_mut(), 0, &mut size) };
    // u64 words keep the TOKEN_USER's pointer aligned.
    let mut buffer = vec![0_u64; usize::try_from(size).unwrap_or(0).div_ceil(8)];
    // SAFETY: `buffer` holds `size` bytes or more.
    let filled = unsafe { GetTokenInformation(token, TokenUser, buffer.as_mut_ptr().cast(), size, &mut size) };
    let result = if filled == 0 {
        Err(io::Error::last_os_error())
    } else {
        // SAFETY: GetTokenInformation wrote a TOKEN_USER at the start of `buffer`.
        let user = unsafe { &*buffer.as_ptr().cast::<TOKEN_USER>() };
        Ok(use_sid(user.User.Sid))
    };
    // SAFETY: `token` was opened above and is closed once.
    unsafe { CloseHandle(token) };
    result
}

#[cfg(test)]
mod tests {
    use std::os::windows::io::AsRawHandle;

    use tokio::net::windows::named_pipe::{ClientOptions, ServerOptions};

    use super::*;

    #[tokio::test]
    async fn a_pipe_this_user_created_is_trusted() {
        let name = format!(r"\\.\pipe\tablepro-owner-test-{}", std::process::id());
        let _server = ServerOptions::new().first_pipe_instance(true).create(&name).unwrap();
        let client = ClientOptions::new().open(&name).unwrap();

        assert!(owned_by_user_or_system(client.as_raw_handle()).unwrap());
    }
}
