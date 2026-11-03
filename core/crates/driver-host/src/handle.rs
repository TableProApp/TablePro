// The host's side of one open driver: calls go out as protobuf, each answer comes back once on whatever thread
// the driver finishes on, and rows arrive as Arrow structs the host moves out and the driver later frees.

use std::ffi::c_void;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{PoisonError, RwLock};
use std::time::Duration;

use arrow_array::{Array, RecordBatch, StructArray};
use arrow_data::ffi::FFI_ArrowArray;
use arrow_schema::ffi::FFI_ArrowSchema;
use prost::Message;
use tablepro_driver_abi::ffi::{ArrowBatch, Bytes, DriverApi, status};
use tablepro_driver_abi::proto::{Request, Response, response};
use tokio::sync::oneshot;

use crate::error::PluginError;

pub struct Reply {
    pub status: i32,
    pub response: Response,
    pub rows: Option<RecordBatch>,
}

impl Reply {
    pub fn into_result(self) -> Result<Self, PluginError> {
        if self.status == status::OK {
            return Ok(self);
        }
        let (codes, message) = match self.response.kind {
            Some(response::Kind::Error(error)) => (error.codes, error.message),
            _ => (Vec::new(), String::new()),
        };
        Err(PluginError::Call {
            status: self.status,
            codes,
            message,
        })
    }
}

type Answer = Box<dyn FnOnce(Reply) + Send>;

pub struct DriverHandle {
    api: DriverApi,
    next_call: AtomicU64,
    // Read for every call into the driver, written by shutdown, which frees the instance: no call can be inside
    // the driver then. A completion never touches it, so one that fires inside `call` cannot deadlock.
    shut_down: RwLock<bool>,
}

// The driver's table is safe to use from any thread: the ABI says so for every entry.
unsafe impl Send for DriverHandle {}
unsafe impl Sync for DriverHandle {}

pub struct PendingCall {
    pub call_id: u64,
    answer: oneshot::Receiver<Reply>,
}

impl PendingCall {
    pub async fn reply(self) -> Reply {
        self.answer.await.unwrap_or_else(|_| dropped())
    }
}

impl DriverHandle {
    /// # Safety
    /// The table and callbacks must be valid, and ownership of its live instance transfers exclusively here.
    pub unsafe fn from_api(api: DriverApi) -> Self {
        Self {
            api,
            next_call: AtomicU64::new(1),
            shut_down: RwLock::new(false),
        }
    }

    pub fn negotiated_minor(&self) -> u16 {
        self.api.abi_minor
    }

    // Starts a call. An Err is the status of a call the driver refused, with no answer to wait for.
    pub fn start(&self, request: &Request) -> Result<PendingCall, i32> {
        self.start_bytes(&request.encode_to_vec())
    }

    pub fn start_bytes(&self, bytes: &[u8]) -> Result<PendingCall, i32> {
        let (sender, answer) = oneshot::channel();
        let call_id = self.send(
            bytes,
            Box::new(move |reply| {
                let _ = sender.send(reply);
            }),
        )?;
        Ok(PendingCall { call_id, answer })
    }

    pub async fn call(&self, request: &Request) -> Result<Reply, i32> {
        Ok(self.start(request)?.reply().await)
    }

    // For a thread that may block, such as an install. Gives up waiting after `timeout` and cancels the call.
    pub fn call_blocking(&self, request: &Request, timeout: Duration) -> Result<Reply, i32> {
        let (sender, answer) = mpsc::channel();
        let call_id = self.send(
            &request.encode_to_vec(),
            Box::new(move |reply| {
                let _ = sender.send(reply);
            }),
        )?;
        match answer.recv_timeout(timeout) {
            Ok(reply) => Ok(reply),
            Err(_) => {
                self.cancel(call_id);
                answer.recv_timeout(timeout).map_err(|_| status::CANCELLED)
            }
        }
    }

    fn send(&self, bytes: &[u8], answer: Answer) -> Result<u64, i32> {
        let shut_down = self.shut_down.read().unwrap_or_else(PoisonError::into_inner);
        if *shut_down {
            return Err(status::SHUT_DOWN);
        }
        let call_id = self.next_call.fetch_add(1, Ordering::SeqCst);
        let context = Box::into_raw(Box::new(answer)).cast::<c_void>();
        let code = unsafe { (self.api.call)(self.api.instance, call_id, Bytes::from_slice(bytes), on_done, context) };
        if code != status::OK {
            // Refused, so no completion runs and the context is still the host's.
            drop(unsafe { Box::from_raw(context.cast::<Answer>()) });
            return Err(code);
        }
        drop(shut_down);
        Ok(call_id)
    }

    pub fn cancel(&self, call_id: u64) -> i32 {
        let shut_down = self.shut_down.read().unwrap_or_else(PoisonError::into_inner);
        if *shut_down {
            return status::SHUT_DOWN;
        }
        unsafe { (self.api.cancel)(self.api.instance, call_id) }
    }

    // Blocks until the driver's threads are gone or `timeout` passes, so it runs on a thread that may block,
    // never on a runtime worker. True when no driver thread is left. Later calls answer SHUT_DOWN.
    pub fn shutdown(&self, timeout: Duration) -> bool {
        let mut shut_down = self.shut_down.write().unwrap_or_else(PoisonError::into_inner);
        if *shut_down {
            return true;
        }
        *shut_down = true;
        let millis = u32::try_from(timeout.as_millis()).unwrap_or(u32::MAX);
        unsafe { (self.api.shutdown)(self.api.instance, millis) == 0 }
    }
}

impl Drop for DriverHandle {
    fn drop(&mut self) {
        let shut_down = *self.shut_down.read().unwrap_or_else(PoisonError::into_inner);
        if !shut_down {
            let handle = Unshut(self.api.instance, self.api.shutdown);
            // Off whatever thread drops it, which may be a runtime worker that must not block.
            let _ = std::thread::Builder::new()
                .name("tablepro-driver-shutdown".to_owned())
                .spawn(move || handle.run());
        }
    }
}

struct Unshut(*mut c_void, tablepro_driver_abi::ffi::ShutdownFn);

// The instance is the driver's, usable from any thread.
unsafe impl Send for Unshut {}

impl Unshut {
    fn run(self) {
        unsafe { (self.1)(self.0, 5_000) };
    }
}

fn dropped() -> Reply {
    Reply {
        status: status::DRIVER,
        response: Response::error("abi.dropped", "the answer to a call was lost"),
        rows: None,
    }
}

unsafe extern "C" fn on_done(context: *mut c_void, _call_id: u64, status: i32, response: Bytes, rows: *mut ArrowBatch) {
    // A panic here would unwind into the driver's frames, so it ends the process instead.
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let answer = unsafe { Box::from_raw(context.cast::<Answer>()) };
        let (status, response) = match Response::decode(unsafe { response.as_slice() }) {
            Ok(response) => (status, response),
            Err(error) => (
                tablepro_driver_abi::ffi::status::DRIVER,
                Response::error("abi.bad_response", error.to_string()),
            ),
        };
        let reply = match unsafe { import_rows(rows) } {
            Ok(rows) => Reply { status, response, rows },
            Err(detail) => Reply {
                status: tablepro_driver_abi::ffi::status::DRIVER,
                response: Response::error("abi.bad_rows", detail),
                rows: None,
            },
        };
        answer(reply);
    }));
    if result.is_err() {
        std::process::abort();
    }
}

// Moves the structs out, leaving release == NULL in the driver's copies, so the batch is freed later by the
// driver's own release callback and never by the host's allocator.
unsafe fn import_rows(rows: *mut ArrowBatch) -> Result<Option<RecordBatch>, String> {
    let Some(rows) = (unsafe { rows.as_ref() }) else {
        return Ok(None);
    };
    if rows.array.is_null() || rows.schema.is_null() {
        return Err("the driver sent a batch with no array or schema".to_owned());
    }
    let array = unsafe { FFI_ArrowArray::from_raw(rows.array) };
    let schema = unsafe { FFI_ArrowSchema::from_raw(rows.schema) };
    let data = unsafe { arrow_array::ffi::from_ffi(array, &schema) }.map_err(|error| error.to_string())?;
    let array = arrow_array::make_array(data);
    let Some(columns) = array.as_any().downcast_ref::<StructArray>() else {
        return Err("the driver's batch is not a struct array".to_owned());
    };
    if columns.null_count() > 0 {
        return Err("the driver's batch marks whole rows null".to_owned());
    }
    Ok(Some(RecordBatch::from(columns.clone())))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn malformed_response_cannot_report_success() {
        let (sender, receiver) = mpsc::channel();
        let answer: Answer = Box::new(move |reply| sender.send(reply).unwrap());
        let context = Box::into_raw(Box::new(answer)).cast::<c_void>();
        unsafe { on_done(context, 1, status::OK, Bytes::from_slice(&[0xff]), std::ptr::null_mut()) };

        let error = receiver.recv().unwrap().into_result().err().unwrap();
        assert!(
            matches!(error, PluginError::Call { status: status::DRIVER, ref codes, .. } if codes == &["abi.bad_response"])
        );
    }
}
