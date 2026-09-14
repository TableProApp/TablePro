use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};

use tablepro_core::value::{DecimalParseError, SqlDecimal};

const ONE_MIB: usize = 1024 * 1024;

static LARGEST_ALLOCATION: AtomicUsize = AtomicUsize::new(0);

struct CountingAllocator;

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        LARGEST_ALLOCATION.fetch_max(layout.size(), Ordering::SeqCst);
        // SAFETY: the layout comes from the caller of GlobalAlloc::alloc and is forwarded unchanged.
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        // SAFETY: the pointer was returned by System through this allocator with the same layout.
        unsafe { System.dealloc(pointer, layout) }
    }

    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        LARGEST_ALLOCATION.fetch_max(new_size, Ordering::SeqCst);
        // SAFETY: the pointer and layout were produced by System through this allocator.
        unsafe { System.realloc(pointer, layout, new_size) }
    }
}

#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

#[test]
fn hostile_decimals_fail_before_allocating() {
    let inputs = [
        "1e2147483647".to_owned(),
        "1e-2147483647".to_owned(),
        format!("1e{}", "9".repeat(20)),
        format!("0.{}", "0".repeat(20_000)),
    ];
    LARGEST_ALLOCATION.store(0, Ordering::SeqCst);

    let results: Vec<Result<SqlDecimal, DecimalParseError>> = inputs.iter().map(|input| input.parse()).collect();

    assert!(LARGEST_ALLOCATION.load(Ordering::SeqCst) <= ONE_MIB);
    assert!(matches!(results[0], Err(DecimalParseError::TooManyDigits { .. })));
    assert!(matches!(results[1], Err(DecimalParseError::TooManyDigits { .. })));
    assert!(matches!(results[2], Err(DecimalParseError::ExponentOutOfRange)));
    assert!(matches!(results[3], Err(DecimalParseError::TooManyDigits { .. })));
}
