use std::io;

use windows_sys::Win32::Foundation::{CloseHandle, ERROR_ACCESS_DENIED, FALSE, HANDLE};
use windows_sys::Win32::Security::{EqualSid, GetTokenInformation, PSID, TOKEN_QUERY, TOKEN_USER, TokenUser};
use windows_sys::Win32::System::Threading::{
    GetCurrentProcess, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION,
};

// A process this user may not open, as another user's or one run as administrator, is not taken for this user's.
pub(super) fn runs_as_this_user(pid: u32) -> io::Result<bool> {
    // SAFETY: the pseudo handle needs no close.
    let ours = token_user(unsafe { GetCurrentProcess() })?;
    // SAFETY: no handle is inherited; a null result is checked before use.
    let process = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid) };
    if process.is_null() {
        let error = io::Error::last_os_error();
        return match error.raw_os_error() == Some(ERROR_ACCESS_DENIED.cast_signed()) {
            true => Ok(false),
            false => Err(error),
        };
    }
    let process = Owned(process);
    let theirs = match token_user(process.0) {
        Ok(theirs) => theirs,
        Err(error) if error.raw_os_error() == Some(ERROR_ACCESS_DENIED.cast_signed()) => return Ok(false),
        Err(error) => return Err(error),
    };
    // SAFETY: both SIDs point into buffers GetTokenInformation filled, alive until the end of this call.
    Ok(unsafe { EqualSid(sid(&ours), sid(&theirs)) } != 0)
}

// TOKEN_USER and the SID it points at, in words so the structure's pointer is aligned.
fn token_user(process: HANDLE) -> io::Result<Vec<usize>> {
    let mut token: HANDLE = std::ptr::null_mut();
    // SAFETY: `token` is a valid out pointer; it is closed by `Owned`.
    if unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let token = Owned(token);
    let mut bytes: u32 = 0;
    // SAFETY: a null buffer of length 0 only asks for the size, which the call fails with.
    let _ = unsafe { GetTokenInformation(token.0, TokenUser, std::ptr::null_mut(), 0, &mut bytes) };
    if bytes == 0 {
        return Err(io::Error::last_os_error());
    }
    let mut buffer = vec![
        0_usize;
        usize::try_from(bytes)
            .map_err(io::Error::other)?
            .div_ceil(size_of::<usize>())
    ];
    // SAFETY: `buffer` holds at least `bytes` bytes, aligned for TOKEN_USER.
    let filled = unsafe { GetTokenInformation(token.0, TokenUser, buffer.as_mut_ptr().cast(), bytes, &mut bytes) };
    if filled == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(buffer)
}

fn sid(user: &[usize]) -> PSID {
    // SAFETY: `user` was filled by GetTokenInformation(TokenUser), which starts with TOKEN_USER.
    unsafe { (*user.as_ptr().cast::<TOKEN_USER>()).User.Sid }
}

struct Owned(HANDLE);

impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: a handle this module opened and nothing else closes.
        let _ = unsafe { CloseHandle(self.0) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn this_process_runs_as_this_user() {
        assert!(runs_as_this_user(std::process::id()).unwrap());
    }
}
