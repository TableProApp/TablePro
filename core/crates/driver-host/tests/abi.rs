#![expect(
    clippy::unwrap_used,
    clippy::panic,
    reason = "a driver written to misbehave, and setup helpers that fail a test as the tests themselves do"
)]

// What the ABI promises, held against a driver written to break it: a panic in a call or in a driver task, a
// completion dropped unanswered, a cancel, a shutdown with work in flight, and rows freed by the side that made
// them (core/docs/decisions/0004-driver-plugin-abi.md).

use std::collections::HashMap;
use std::ptr::NonNull;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use arrow_array::{Array, Int64Array, RecordBatch};
use arrow_buffer::{Buffer, ScalarBuffer};
use arrow_schema::{DataType, Field, Schema};
use tablepro_driver_abi::export::{self, Completion, Driver, Host, Outcome};
use tablepro_driver_abi::ffi::{self, HostApi, status};
use tablepro_driver_abi::proto::{self, Request, Response, request, response};
use tablepro_driver_host::{DriverHandle, host_api, open_static};
use tokio::runtime::{Handle, Runtime};
use tokio_util::sync::CancellationToken;

static THREADS: AtomicUsize = AtomicUsize::new(0);
static FREED: AtomicUsize = AtomicUsize::new(0);

struct Unruly {
    runtime: Mutex<Option<Runtime>>,
    handle: Handle,
    calls: Mutex<HashMap<u64, CancellationToken>>,
    minor: u16,
}

// Owns the bytes of an Arrow buffer, and counts the times the driver's side frees it.
struct Tracked(Vec<i64>);

impl Drop for Tracked {
    fn drop(&mut self) {
        FREED.fetch_add(1, Ordering::SeqCst);
    }
}

fn tracked_batch() -> RecordBatch {
    let owner = Arc::new(Tracked(vec![10, 20, 30]));
    let pointer = NonNull::new(owner.0.as_ptr().cast_mut().cast::<u8>()).unwrap();
    let buffer = unsafe { Buffer::from_custom_allocation(pointer, 3 * size_of::<i64>(), owner) };
    let column = Int64Array::new(ScalarBuffer::new(buffer, 0, 3), None);
    let schema = Schema::new(vec![Field::new("n", DataType::Int64, false)]);
    RecordBatch::try_new(Arc::new(schema), vec![Arc::new(column)]).unwrap()
}

impl Driver for Unruly {
    fn open(_host: Host, negotiated_minor: u16) -> Result<Self, String> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .on_thread_start(|| {
                THREADS.fetch_add(1, Ordering::SeqCst);
            })
            .on_thread_stop(|| {
                THREADS.fetch_sub(1, Ordering::SeqCst);
            })
            .build()
            .map_err(|error| error.to_string())?;
        Ok(Self {
            handle: runtime.handle().clone(),
            runtime: Mutex::new(Some(runtime)),
            calls: Mutex::new(HashMap::new()),
            minor: negotiated_minor,
        })
    }

    fn call(self: &Arc<Self>, call_id: u64, request: request::Kind, completion: Completion) {
        let request::Kind::Read(read) = request else {
            completion.finish(Outcome::ok(Response::of(response::Kind::Opened(proto::Opened {
                connection: u64::from(self.minor),
                server_version: String::new(),
            }))));
            return;
        };
        match read.sql.as_str() {
            "panic here" => panic!("boom in call"),
            "panic later" => {
                self.handle
                    .spawn(completion.run_guarded_async(async { panic!("boom in a driver task") }));
            }
            "panic exporting" => completion.finish(panicking_rows()),
            "panic exporting later" => {
                self.handle.spawn(async { completion.finish(panicking_rows()) });
            }
            "drop" => drop(completion),
            "rows" => completion.finish(Outcome::with_rows(
                Response::of(response::Kind::ReadDone(proto::ReadDone {
                    rows: 3,
                    truncated: false,
                })),
                tracked_batch(),
            )),
            _ => {
                let token = CancellationToken::new();
                self.calls.lock().unwrap().insert(call_id, token.clone());
                self.handle.spawn(completion.run_guarded_async(async move {
                    token.cancelled().await;
                    Outcome::fail(status::CANCELLED, Response::error("driver.cancelled", "cancelled"))
                }));
            }
        }
    }

    fn cancel(&self, call_id: u64) -> bool {
        self.calls
            .lock()
            .unwrap()
            .remove(&call_id)
            .map(|token| token.cancel())
            .is_some()
    }

    fn shutdown(&self, timeout: Duration) -> bool {
        for (_, token) in self.calls.lock().unwrap().drain() {
            token.cancel();
        }
        if let Some(runtime) = self.runtime.lock().unwrap().take() {
            runtime.shutdown_timeout(timeout);
        }
        THREADS.load(Ordering::SeqCst) == 0
    }
}

fn read(sql: &str) -> Request {
    Request::of(request::Kind::Read(proto::Read {
        connection: 1,
        sql: sql.to_owned(),
        row_limit: 0,
        timeout_ms: 0,
    }))
}

fn blocking(handle: &DriverHandle, request: &Request) -> tablepro_driver_host::Reply {
    handle.call_blocking(request, Duration::from_secs(10)).unwrap()
}

fn code(response: &Response) -> String {
    match &response.kind {
        Some(response::Kind::Error(error)) => error.codes.join(","),
        _ => String::new(),
    }
}

// One test: the thread count and the freed count are process-wide.
#[test]
fn the_abi_holds_against_a_driver_that_misbehaves() {
    open_respects_the_output_capacity_and_short_host_header();
    the_minor_version_negotiates_down_and_another_major_is_refused();
    assert_eq!(THREADS.load(Ordering::SeqCst), 0);

    let handle = open_static::<Unruly>("unruly").unwrap();
    assert_eq!(handle.negotiated_minor(), ffi::ABI_MINOR);

    let panicked = blocking(&handle, &read("panic here"));
    assert_eq!(panicked.status, status::PANIC);
    assert_eq!(code(&panicked.response), "abi.panic");

    let panicked_later = blocking(&handle, &read("panic later"));
    assert_eq!(panicked_later.status, status::PANIC);
    assert!(format!("{:?}", panicked_later.response).contains("boom in a driver task"));

    for sql in ["panic exporting", "panic exporting later"] {
        let reply = blocking(&handle, &read(sql));
        assert_eq!(reply.status, status::PANIC);
        assert_eq!(code(&reply.response), "abi.panic");
    }

    let dropped = blocking(&handle, &read("drop"));
    assert_eq!(dropped.status, status::DRIVER);
    assert_eq!(code(&dropped.response), "abi.dropped");

    // Still answering after both panics.
    assert_eq!(blocking(&handle, &read("rows")).status, status::OK);
    rows_are_freed_by_the_driver_once_the_host_lets_go(&handle);

    let (sender, answer) = std::sync::mpsc::channel();
    let pending = handle.start(&read("wait")).unwrap();
    let call_id = pending.call_id;
    let waiter = std::thread::spawn(move || {
        let reply = block_on(pending.reply());
        sender.send(reply.status).unwrap();
    });
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(handle.cancel(call_id), status::OK);
    assert_eq!(answer.recv_timeout(Duration::from_secs(10)).unwrap(), status::CANCELLED);
    waiter.join().unwrap();
    assert_eq!(handle.cancel(call_id), status::UNKNOWN_CALL);

    let in_flight = handle.start(&read("wait")).unwrap();
    assert!(THREADS.load(Ordering::SeqCst) > 0);
    assert!(
        handle.shutdown(Duration::from_secs(10)),
        "a driver thread outlived shutdown"
    );
    assert_eq!(THREADS.load(Ordering::SeqCst), 0);
    assert_eq!(block_on(in_flight.reply()).status, status::CANCELLED);
    assert_eq!(handle.start(&read("rows")).err(), Some(status::SHUT_DOWN));
}

fn rows_are_freed_by_the_driver_once_the_host_lets_go(handle: &DriverHandle) {
    let before = FREED.load(Ordering::SeqCst);

    let reply = blocking(handle, &read("rows"));
    let batch = reply.rows.unwrap();

    // The host holds the batch; the driver's copy was moved out, so nothing is freed yet.
    assert_eq!(FREED.load(Ordering::SeqCst), before);
    let column = batch.column(0).as_any().downcast_ref::<Int64Array>().unwrap();
    assert_eq!(column.values(), &[10, 20, 30]);
    drop(batch);
    assert_eq!(FREED.load(Ordering::SeqCst), before + 1);
}

fn block_on<F: std::future::Future>(future: F) -> F::Output {
    tokio::runtime::Builder::new_current_thread()
        .build()
        .unwrap()
        .block_on(future)
}

fn the_minor_version_negotiates_down_and_another_major_is_refused() {
    let mut newer = host_api();
    newer.abi_minor = ffi::ABI_MINOR + 3;
    // host_api uses a process-lifetime callback that ignores its null context.
    let table = unsafe { export::driver_api::<Unruly>(&newer) }.unwrap();
    assert_eq!(table.abi_minor, ffi::ABI_MINOR);
    // This successful open transfers its instance to exactly one handle.
    let handle = unsafe { DriverHandle::from_api(table) };
    let opened = blocking(&handle, &Request::of(request::Kind::Describe(proto::Describe {})));
    let Some(response::Kind::Opened(seen)) = opened.response.kind else {
        panic!("no answer");
    };
    assert_eq!(seen.connection, u64::from(ffi::ABI_MINOR));
    assert!(handle.shutdown(Duration::from_secs(10)));

    let older = HostApi {
        abi_major: ffi::ABI_MAJOR + 1,
        ..host_api()
    };
    // host_api uses a process-lifetime callback that ignores its null context.
    let (code, message) = unsafe { export::driver_api::<Unruly>(&older) }.err().unwrap();
    assert_eq!(code, status::VERSION);
    assert!(message.contains("ABI 2.0"), "{message}");
    assert_eq!(export::negotiate(5, 2), 2);
}

fn open_respects_the_output_capacity_and_short_host_header() {
    #[repr(C, align(8))]
    struct ShortOutput {
        bytes: [u8; 8],
        canary: [u8; 16],
    }
    let mut short = ShortOutput {
        bytes: [0xa5; 8],
        canary: [0x5a; 16],
    };
    let code = unsafe {
        export::open::<Unruly>(
            &host_api(),
            short.bytes.as_mut_ptr().cast(),
            short.bytes.len(),
            std::ptr::null_mut(),
        )
    };
    assert_eq!(code, status::BAD_REQUEST);
    assert_eq!(short.bytes, [0xa5; 8]);
    assert_eq!(short.canary, [0x5a; 16]);
    assert_eq!(THREADS.load(Ordering::SeqCst), 0);

    #[repr(C, align(8))]
    struct ShortHost {
        size: u32,
    }
    let header = ShortHost {
        size: size_of::<u32>() as u32,
    };
    let mut out = std::mem::MaybeUninit::<ffi::DriverApi>::uninit();
    let code = unsafe {
        export::open::<Unruly>(
            std::ptr::from_ref(&header).cast(),
            out.as_mut_ptr(),
            size_of::<ffi::DriverApi>(),
            std::ptr::null_mut(),
        )
    };
    assert_eq!(code, status::BAD_REQUEST);
    assert_eq!(THREADS.load(Ordering::SeqCst), 0);

    #[repr(C)]
    struct FutureOutput {
        table: std::mem::MaybeUninit<ffi::DriverApi>,
        extension: [u8; 16],
    }
    let mut future = FutureOutput {
        table: std::mem::MaybeUninit::uninit(),
        extension: [0xa5; 16],
    };
    let mut newer = host_api();
    newer.abi_minor += 1;
    let code = unsafe {
        export::open::<Unruly>(
            &newer,
            future.table.as_mut_ptr(),
            size_of::<FutureOutput>(),
            std::ptr::null_mut(),
        )
    };
    assert_eq!(code, status::OK);
    assert_eq!(future.extension, [0xa5; 16]);
    let table = unsafe { future.table.assume_init() };
    assert_eq!(table.size as usize, size_of::<ffi::DriverApi>());
    assert_eq!(table.abi_minor, ffi::ABI_MINOR);
    // This successful open transfers its instance to exactly one handle.
    let handle = unsafe { DriverHandle::from_api(table) };
    assert!(handle.shutdown(Duration::from_secs(10)));
}

#[derive(Debug)]
struct PanickingArray(Int64Array);

// All storage and downcasts use the real array; only exporting its data fails.
unsafe impl Array for PanickingArray {
    fn as_any(&self) -> &dyn std::any::Any {
        self.0.as_any()
    }
    fn to_data(&self) -> arrow_data::ArrayData {
        panic!("boom exporting rows")
    }
    fn into_data(self) -> arrow_data::ArrayData {
        panic!("boom exporting rows")
    }
    fn data_type(&self) -> &DataType {
        self.0.data_type()
    }
    fn slice(&self, offset: usize, length: usize) -> arrow_array::ArrayRef {
        Arc::new(self.0.slice(offset, length))
    }
    fn len(&self) -> usize {
        self.0.len()
    }
    fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
    fn offset(&self) -> usize {
        self.0.offset()
    }
    fn nulls(&self) -> Option<&arrow_buffer::NullBuffer> {
        self.0.nulls()
    }
    fn get_buffer_memory_size(&self) -> usize {
        self.0.get_buffer_memory_size()
    }
    fn get_array_memory_size(&self) -> usize {
        self.0.get_array_memory_size()
    }
}

fn panicking_rows() -> Outcome {
    let array = PanickingArray(Int64Array::from(vec![1]));
    let schema = Schema::new(vec![Field::new("n", DataType::Int64, false)]);
    let batch = RecordBatch::try_new(Arc::new(schema), vec![Arc::new(array)]).unwrap();
    Outcome::with_rows(
        Response::of(response::Kind::ReadDone(proto::ReadDone {
            rows: 1,
            truncated: false,
        })),
        batch,
    )
}
