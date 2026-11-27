use windows_sys::Win32::Foundation::ERROR_SUCCESS;
use windows_sys::Win32::System::Registry::{HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ, RRF_SUBKEY_WOW6464KEY, RegGetValueW};

// 36 characters and the NUL, with room to spare.
const UNITS: usize = 64;

// The 64-bit view holds it; a 32-bit process would otherwise read WOW6432Node, which has none.
pub(crate) fn read_machine_guid() -> Result<String, String> {
    let key = wide(r"SOFTWARE\Microsoft\Cryptography");
    let value = wide("MachineGuid");
    let mut buffer = [0u16; UNITS];
    let mut size = u32::try_from(std::mem::size_of_val(&buffer)).unwrap_or(u32::MAX);
    // SAFETY: both names are NUL-terminated and outlive the call; `size` is the buffer's length in bytes.
    let status = unsafe {
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            key.as_ptr(),
            value.as_ptr(),
            RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY,
            std::ptr::null_mut(),
            buffer.as_mut_ptr().cast(),
            &raw mut size,
        )
    };
    if status != ERROR_SUCCESS {
        return Err(format!("MachineGuid could not be read (error {status})"));
    }
    let units = (size as usize / 2).min(UNITS);
    let text = String::from_utf16(&buffer[..units]).map_err(|_| "MachineGuid is not UTF-16 text".to_owned())?;
    Ok(text.trim_end_matches('\0').to_owned())
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

#[cfg(test)]
mod tests {
    use tablepro_account::MachineId;

    use super::*;

    #[test]
    fn this_machine_has_a_guid_the_account_derives_an_id_from() {
        let guid = read_machine_guid().unwrap();

        assert!(MachineId::derive_machine_guid(&guid).is_some(), "{guid:?}");
    }
}
