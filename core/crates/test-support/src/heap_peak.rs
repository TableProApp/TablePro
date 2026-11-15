use std::alloc::{GlobalAlloc, Layout, System};
use std::future::Future;
use std::sync::atomic::{AtomicUsize, Ordering};

// The global allocator of a test binary that bounds what a read holds on the heap, on every platform. It counts the
// whole process, so such a binary holds that one test alone.
pub struct HeapCounter;

static HELD: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);

fn grew(by: usize) {
    let held = HELD.fetch_add(by, Ordering::Relaxed).saturating_add(by);
    PEAK.fetch_max(held, Ordering::Relaxed);
}

// SAFETY: every call goes to the system allocator with the caller's own arguments; the counters only watch.
unsafe impl GlobalAlloc for HeapCounter {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        // SAFETY: the caller keeps `alloc`'s contract, which is the system allocator's.
        let pointer = unsafe { System.alloc(layout) };
        if !pointer.is_null() {
            grew(layout.size());
        }
        pointer
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        // SAFETY: `pointer` came from this allocator, which is the system's, with `layout`.
        unsafe { System.dealloc(pointer, layout) };
        HELD.fetch_sub(layout.size(), Ordering::Relaxed);
    }

    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        // SAFETY: as for `dealloc`, with the caller's `new_size`.
        let moved = unsafe { System.realloc(pointer, layout, new_size) };
        if !moved.is_null() {
            match new_size.checked_sub(layout.size()) {
                Some(more) => grew(more),
                None => {
                    HELD.fetch_sub(layout.size() - new_size, Ordering::Relaxed);
                }
            }
        }
        moved
    }
}

// How far the heap rose above where it stood when `read` started, while it ran. Without `HeapCounter` installed it is 0.
pub async fn heap_peak_of<T>(read: impl Future<Output = T>) -> (T, usize) {
    let start = HELD.load(Ordering::Relaxed);
    PEAK.store(start, Ordering::Relaxed);
    let value = read.await;
    (value, PEAK.load(Ordering::Relaxed).saturating_sub(start))
}
