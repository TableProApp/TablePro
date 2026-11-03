// Mirrors include/tablepro_driver.h, which states the contract.

use std::ffi::{c_char, c_void};

use arrow_data::ffi::FFI_ArrowArray;
use arrow_schema::ffi::FFI_ArrowSchema;

pub const MAGIC: u32 = 0x5450_4456;
pub const ABI_MAJOR: u16 = 1;
pub const ABI_MINOR: u16 = 0;

pub const DESCRIPTOR_SYMBOL: &[u8] = b"tablepro_driver_descriptor\0";
pub const OPEN_SYMBOL: &[u8] = b"tablepro_driver_open\0";

#[repr(C)]
pub struct Descriptor {
    pub magic: u32,
    pub size: u32,
    pub abi_major: u16,
    pub abi_minor: u16,
    pub panic_unwind: u8,
    pub reserved: [u8; 7],
    pub driver_id: *const c_char,
    pub driver_version: *const c_char,
}

// The descriptor only points at static NUL-terminated strings.
unsafe impl Sync for Descriptor {}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Bytes {
    pub ptr: *const u8,
    pub len: usize,
}

impl Bytes {
    pub fn from_slice(slice: &[u8]) -> Self {
        Self {
            ptr: slice.as_ptr(),
            len: slice.len(),
        }
    }

    /// # Safety
    /// `ptr` points at `len` readable bytes for the returned lifetime, or `len` is 0.
    pub unsafe fn as_slice<'a>(self) -> &'a [u8] {
        if self.len == 0 || self.ptr.is_null() {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(self.ptr, self.len) }
        }
    }
}

#[repr(C)]
pub struct ErrorBuf {
    pub ptr: *mut u8,
    pub cap: usize,
    pub len: usize,
}

impl ErrorBuf {
    /// # Safety
    /// `buf` is null or points at a valid `ErrorBuf` whose `ptr` has `cap` writable bytes.
    pub unsafe fn write(buf: *mut ErrorBuf, message: &str) {
        let Some(buf) = (unsafe { buf.as_mut() }) else {
            return;
        };
        if buf.ptr.is_null() {
            return;
        }
        let mut end = message.len().min(buf.cap);
        while !message.is_char_boundary(end) {
            end -= 1;
        }
        unsafe { std::ptr::copy_nonoverlapping(message.as_ptr(), buf.ptr, end) };
        buf.len = end;
    }
}

pub mod status {
    pub const OK: i32 = 0;
    pub const VERSION: i32 = 1;
    pub const BAD_REQUEST: i32 = 2;
    pub const PANIC: i32 = 3;
    pub const CANCELLED: i32 = 4;
    pub const DRIVER: i32 = 5;
    pub const UNSUPPORTED: i32 = 6;
    pub const SHUT_DOWN: i32 = 7;
    pub const UNKNOWN_CALL: i32 = 8;
}

pub mod log_level {
    pub const ERROR: i32 = 1;
    pub const WARN: i32 = 2;
    pub const INFO: i32 = 3;
    pub const DEBUG: i32 = 4;
}

pub type LogFn = unsafe extern "C" fn(ctx: *mut c_void, level: i32, message: Bytes);

#[repr(C)]
pub struct HostApi {
    pub size: u32,
    pub abi_major: u16,
    pub abi_minor: u16,
    pub ctx: *mut c_void,
    pub log: LogFn,
}

#[repr(C)]
pub struct ArrowBatch {
    pub schema: *mut FFI_ArrowSchema,
    pub array: *mut FFI_ArrowArray,
}

pub type CompletionFn =
    unsafe extern "C" fn(ctx: *mut c_void, call_id: u64, status: i32, response: Bytes, rows: *mut ArrowBatch);

pub type CallFn = unsafe extern "C" fn(
    instance: *mut c_void,
    call_id: u64,
    request: Bytes,
    done: CompletionFn,
    done_ctx: *mut c_void,
) -> i32;
pub type CancelFn = unsafe extern "C" fn(instance: *mut c_void, call_id: u64) -> i32;
pub type ShutdownFn = unsafe extern "C" fn(instance: *mut c_void, timeout_ms: u32) -> i32;

#[repr(C)]
pub struct DriverApi {
    pub size: u32,
    pub abi_major: u16,
    pub abi_minor: u16,
    pub instance: *mut c_void,
    pub call: CallFn,
    pub cancel: CancelFn,
    pub shutdown: ShutdownFn,
}

pub type OpenFn =
    unsafe extern "C" fn(host: *const HostApi, out: *mut DriverApi, out_size: usize, error: *mut ErrorBuf) -> i32;

#[cfg(test)]
mod tests {
    use super::*;

    // The host reads these fields from a driver of any major, so they may never move.
    #[test]
    fn the_descriptor_keeps_its_offsets() {
        assert_eq!(std::mem::offset_of!(Descriptor, magic), 0);
        assert_eq!(std::mem::offset_of!(Descriptor, size), 4);
        assert_eq!(std::mem::offset_of!(Descriptor, abi_major), 8);
        assert_eq!(std::mem::offset_of!(Descriptor, abi_minor), 10);
        assert_eq!(std::mem::offset_of!(Descriptor, panic_unwind), 12);
        assert_eq!(std::mem::offset_of!(Descriptor, driver_id), 24);
        assert_eq!(std::mem::offset_of!(Descriptor, driver_version), 32);
    }

    #[test]
    fn an_error_message_is_cut_at_a_character_boundary() {
        let mut storage = [0u8; 4];
        let mut buf = ErrorBuf {
            ptr: storage.as_mut_ptr(),
            cap: storage.len(),
            len: 0,
        };

        unsafe { ErrorBuf::write(&mut buf, "aé€") };

        assert_eq!(&storage[..buf.len], "aé".as_bytes());
    }
}
