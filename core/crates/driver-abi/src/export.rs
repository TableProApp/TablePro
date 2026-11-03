// The driver's side of the ABI. A driver implements `Driver`; `export_driver!` emits the two C symbols for a
// library the host loads, and `driver_api` builds the same table in-process for a driver linked statically.

use std::any::Any;
use std::ffi::{CStr, c_void};
use std::future::Future;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;
use std::time::Duration;

use arrow_array::{Array, RecordBatch, StructArray};
use arrow_data::ffi::FFI_ArrowArray;
use arrow_schema::ffi::FFI_ArrowSchema;
use futures::FutureExt;
use prost::Message;

use crate::ffi::{self, ArrowBatch, Bytes, CompletionFn, DriverApi, ErrorBuf, HostApi, status};
use crate::proto::{Request, Response, request};

pub trait Driver: Send + Sync + Sized + 'static {
    fn open(host: Host, negotiated_minor: u16) -> Result<Self, String>;

    // Consumes `completion` exactly once, now or later, on any thread.
    fn call(self: &Arc<Self>, call_id: u64, request: request::Kind, completion: Completion);

    // Whether a call with this id was still running.
    fn cancel(&self, call_id: u64) -> bool;

    // Cancels every call and stops the driver's threads. False when a thread may still be running.
    fn shutdown(&self, timeout: Duration) -> bool;
}

#[derive(Clone, Copy)]
pub struct Host {
    ctx: SendPtr,
    log: ffi::LogFn,
}

impl Host {
    pub fn log(&self, level: i32, message: &str) {
        unsafe { (self.log)(self.ctx.0, level, Bytes::from_slice(message.as_bytes())) }
    }
}

#[derive(Clone, Copy)]
struct SendPtr(*mut c_void);

// The host promises its context and every completion context are usable from any thread.
unsafe impl Send for SendPtr {}
unsafe impl Sync for SendPtr {}

pub struct Completion {
    done: CompletionFn,
    ctx: SendPtr,
    call_id: u64,
    fired: bool,
}

impl Completion {
    pub fn call_id(&self) -> u64 {
        self.call_id
    }

    pub fn finish(mut self, outcome: Outcome) {
        self.fire(outcome);
    }

    fn fire(&mut self, outcome: Outcome) {
        if self.fired {
            return;
        }
        self.fired = true;
        let Outcome {
            mut status,
            mut response,
            rows,
        } = outcome;
        let mut exported = None;
        if let Some(batch) = rows {
            let data = StructArray::from(batch).into_data();
            match arrow_array::ffi::to_ffi(&data) {
                Ok(pair) => exported = Some(pair),
                Err(error) => {
                    status = status::DRIVER;
                    response = Response::error("abi.rows_export", error.to_string());
                }
            }
        }
        let bytes = response.encode_to_vec();
        let mut slot = exported.as_mut().map(|(array, schema)| ArrowBatch {
            schema: std::ptr::from_mut::<FFI_ArrowSchema>(schema),
            array: std::ptr::from_mut::<FFI_ArrowArray>(array),
        });
        let rows = slot
            .as_mut()
            .map_or(std::ptr::null_mut(), std::ptr::from_mut::<ArrowBatch>);
        unsafe { (self.done)(self.ctx.0, self.call_id, status, Bytes::from_slice(&bytes), rows) };
        // What the host did not move out is released here, by this copy of arrow.
        drop(exported);
    }

    // Panics in `work` answer PANIC, so a driver bug never unwinds into a runtime or across the C boundary.
    pub fn run_guarded(self, work: impl FnOnce() -> Outcome) {
        let outcome = catch_unwind(AssertUnwindSafe(work)).unwrap_or_else(|payload| Outcome::panicked(&*payload));
        self.finish(outcome);
    }

    pub async fn run_guarded_async(self, work: impl Future<Output = Outcome>) {
        self.finish(guarded(work).await);
    }
}

impl Drop for Completion {
    fn drop(&mut self) {
        // A completion dropped without an answer still answers, so the host never waits forever.
        if std::thread::panicking() {
            self.fire(Outcome::fail(
                status::PANIC,
                Response::error("abi.panic", "the driver panicked while handling the call"),
            ));
        } else {
            self.fire(Outcome::fail(
                status::DRIVER,
                Response::error("abi.dropped", "the driver dropped the call without answering"),
            ));
        }
    }
}

pub struct Outcome {
    pub status: i32,
    pub response: Response,
    pub rows: Option<RecordBatch>,
}

impl Outcome {
    pub fn ok(response: Response) -> Self {
        Self {
            status: status::OK,
            response,
            rows: None,
        }
    }

    pub fn with_rows(response: Response, rows: RecordBatch) -> Self {
        Self {
            status: status::OK,
            response,
            rows: Some(rows),
        }
    }

    pub fn fail(status: i32, response: Response) -> Self {
        Self {
            status,
            response,
            rows: None,
        }
    }

    pub fn unsupported() -> Self {
        Self::fail(
            status::UNSUPPORTED,
            Response::error("abi.unsupported", "the driver does not know this request"),
        )
    }

    pub fn panicked(payload: &(dyn Any + Send)) -> Self {
        Self::fail(status::PANIC, Response::error("abi.panic", panic_message(payload)))
    }
}

// A panic in `work` becomes a PANIC outcome. tokio would catch it too, but drop the task only after the unwind,
// when the completion can no longer tell a panic from a call it was never given.
pub async fn guarded(work: impl Future<Output = Outcome>) -> Outcome {
    AssertUnwindSafe(work)
        .catch_unwind()
        .await
        .unwrap_or_else(|payload| Outcome::panicked(&*payload))
}

pub fn panic_message(payload: &(dyn Any + Send)) -> String {
    if let Some(text) = payload.downcast_ref::<&str>() {
        (*text).to_owned()
    } else if let Some(text) = payload.downcast_ref::<String>() {
        text.clone()
    } else {
        "a panic with no message".to_owned()
    }
}

pub const fn descriptor(driver_id: &'static CStr, version: &'static CStr) -> ffi::Descriptor {
    ffi::Descriptor {
        magic: ffi::MAGIC,
        size: size_of::<ffi::Descriptor>() as u32,
        abi_major: ffi::ABI_MAJOR,
        abi_minor: ffi::ABI_MINOR,
        panic_unwind: cfg!(panic = "unwind") as u8,
        reserved: [0; 7],
        driver_id: driver_id.as_ptr(),
        driver_version: version.as_ptr(),
    }
}

// A version string from env!("CARGO_PKG_VERSION") with a NUL appended, in a const.
pub const fn version_cstr(bytes: &'static [u8]) -> &'static CStr {
    match CStr::from_bytes_with_nul(bytes) {
        Ok(text) => text,
        Err(_) => c"0.0.0",
    }
}

/// # Safety
/// `host` points to its size header and the bytes it declares; `out` has `out_size` writable bytes.
/// Both pointers are aligned for their types; `error` is null or valid.
pub unsafe fn open<D: Driver>(host: *const HostApi, out: *mut DriverApi, out_size: usize, error: *mut ErrorBuf) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| unsafe {
        open_inner::<D>(host, out, out_size, error)
    }));
    result.unwrap_or_else(|payload| {
        let message = format!("the driver panicked in open: {}", panic_message(&*payload));
        unsafe { ErrorBuf::write(error, &message) };
        status::PANIC
    })
}

unsafe fn open_inner<D: Driver>(
    host: *const HostApi,
    out: *mut DriverApi,
    out_size: usize,
    error: *mut ErrorBuf,
) -> i32 {
    if host.is_null() || out.is_null() || out_size < size_of::<DriverApi>() {
        return status::BAD_REQUEST;
    }
    // A size header can belong to an older, shorter allocation.
    if (unsafe { host.cast::<u32>().read() } as usize) < size_of::<HostApi>() {
        return status::BAD_REQUEST;
    }
    let host = unsafe { &*host };
    if host.abi_major != ffi::ABI_MAJOR {
        let message = format!(
            "the host speaks ABI {}.{}, the driver {}.{}",
            host.abi_major,
            host.abi_minor,
            ffi::ABI_MAJOR,
            ffi::ABI_MINOR
        );
        unsafe { ErrorBuf::write(error, &message) };
        return status::VERSION;
    }
    let negotiated = negotiate(host.abi_minor, ffi::ABI_MINOR);
    let handle = Host {
        ctx: SendPtr(host.ctx),
        log: host.log,
    };
    let driver = match D::open(handle, negotiated) {
        Ok(driver) => Arc::new(driver),
        Err(message) => {
            unsafe { ErrorBuf::write(error, &message) };
            return status::DRIVER;
        }
    };
    let api = DriverApi {
        size: size_of::<DriverApi>() as u32,
        abi_major: ffi::ABI_MAJOR,
        abi_minor: negotiated,
        instance: Arc::into_raw(driver).cast_mut().cast::<c_void>(),
        call: call::<D>,
        cancel: cancel::<D>,
        shutdown: shutdown::<D>,
    };
    unsafe { out.write(api) };
    status::OK
}

pub fn negotiate(host_minor: u16, driver_minor: u16) -> u16 {
    host_minor.min(driver_minor)
}

unsafe fn borrow<D: Driver>(instance: *mut c_void) -> Arc<D> {
    let pointer = instance.cast_const().cast::<D>();
    unsafe { Arc::increment_strong_count(pointer) };
    unsafe { Arc::from_raw(pointer) }
}

unsafe extern "C" fn call<D: Driver>(
    instance: *mut c_void,
    call_id: u64,
    request: Bytes,
    done: CompletionFn,
    done_ctx: *mut c_void,
) -> i32 {
    let mut handed_over = false;
    let result = catch_unwind(AssertUnwindSafe(|| {
        let driver = unsafe { borrow::<D>(instance) };
        let Ok(request) = Request::decode(unsafe { request.as_slice() }) else {
            return status::BAD_REQUEST;
        };
        let completion = Completion {
            done,
            ctx: SendPtr(done_ctx),
            call_id,
            fired: false,
        };
        handed_over = true;
        // A kind this build cannot decode reads as none: a newer host learns the driver lacks it.
        match request.kind {
            Some(kind) => driver.call(call_id, kind, completion),
            None => completion.finish(Outcome::unsupported()),
        }
        status::OK
    }));
    // Once the completion exists it has answered, through an unwind too, so the call counts as accepted.
    match result {
        Ok(code) => code,
        Err(_) if handed_over => status::OK,
        Err(_) => status::PANIC,
    }
}

unsafe extern "C" fn cancel<D: Driver>(instance: *mut c_void, call_id: u64) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let driver = unsafe { borrow::<D>(instance) };
        if driver.cancel(call_id) {
            status::OK
        } else {
            status::UNKNOWN_CALL
        }
    }));
    result.unwrap_or(status::PANIC)
}

unsafe extern "C" fn shutdown<D: Driver>(instance: *mut c_void, timeout_ms: u32) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let driver = unsafe { Arc::from_raw(instance.cast_const().cast::<D>()) };
        let clean = driver.shutdown(Duration::from_millis(u64::from(timeout_ms)));
        drop(driver);
        if clean { 0 } else { 1 }
    }));
    result.unwrap_or(status::PANIC)
}

// The table for a driver linked into the app, through the same entry point a loaded library exports.
pub fn driver_api<D: Driver>(host: &HostApi) -> Result<DriverApi, (i32, String)> {
    let mut out = std::mem::MaybeUninit::<DriverApi>::uninit();
    let mut buffer = vec![0u8; 1024];
    let mut error = ErrorBuf {
        ptr: buffer.as_mut_ptr(),
        cap: buffer.len(),
        len: 0,
    };
    let code = unsafe { open::<D>(host, out.as_mut_ptr(), size_of::<DriverApi>(), &mut error) };
    if code == status::OK {
        Ok(unsafe { out.assume_init() })
    } else {
        Err((code, String::from_utf8_lossy(&buffer[..error.len]).into_owned()))
    }
}

// Emits the two exported symbols. Only a driver's thin plugin crate expands it, so drivers linked statically
// into one binary never clash on these names.
#[macro_export]
macro_rules! export_driver {
    ($driver:ty, $id:literal) => {
        #[unsafe(export_name = "tablepro_driver_descriptor")]
        pub static TABLEPRO_DRIVER_DESCRIPTOR: $crate::ffi::Descriptor = $crate::export::descriptor(
            $id,
            $crate::export::version_cstr(concat!(env!("CARGO_PKG_VERSION"), "\0").as_bytes()),
        );

        /// # Safety
        /// The host loader calls it with valid pointers.
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn tablepro_driver_open(
            host: *const $crate::ffi::HostApi,
            out: *mut $crate::ffi::DriverApi,
            out_size: usize,
            error: *mut $crate::ffi::ErrorBuf,
        ) -> i32 {
            unsafe { $crate::export::open::<$driver>(host, out, out_size, error) }
        }
    };
}
