#[cfg(all(test, mongodb_internal_tracking_arc))]
use crate::id_set::{self, IdSet};
use std::sync::Arc;
#[cfg(all(test, mongodb_internal_tracking_arc))]
use std::sync::Mutex as SyncMutex;

/// An `Arc` that records the backtraces of construction of live clones.  When not compiled
/// with `cfg(mongodb_internal_tracking_arc)`, a zero-cost `Arc` wrapper.
#[derive(Debug)]
pub(crate) struct TrackingArc<T> {
    inner: Arc<Inner<T>>,
    #[cfg(all(test, mongodb_internal_tracking_arc))]
    clone_id: Option<id_set::Id>,
}

#[derive(Debug)]
struct Inner<T> {
    value: T,
    #[cfg(all(test, mongodb_internal_tracking_arc))]
    clones: SyncMutex<IdSet<backtrace::Backtrace>>,
}

impl<T> TrackingArc<T> {
    pub(crate) fn new(value: T) -> Self {
        Self {
            inner: Arc::new(Inner {
                value,
                #[cfg(all(test, mongodb_internal_tracking_arc))]
                clones: SyncMutex::new(IdSet::new()),
            }),
            #[cfg(all(test, mongodb_internal_tracking_arc))]
            clone_id: None,
        }
    }

    #[allow(unused)]
    pub(crate) fn try_unwrap(tracked: Self) -> Result<T, Self> {
        let inner = tracked.inner.clone();
        #[cfg(all(test, mongodb_internal_tracking_arc))]
        let clone_id = {
            let mut tracked = tracked;
            tracked.clone_id.take()
        };
        match Arc::try_unwrap(inner) {
            Ok(inner) => Ok(inner.value),
            Err(inner) => Err(Self {
                inner,
                #[cfg(all(test, mongodb_internal_tracking_arc))]
                clone_id,
            }),
        }
    }

    #[cfg(feature = "in-use-encryption")]
    pub(crate) fn downgrade(tracked: &Self) -> Weak<T> {
        Weak {
            inner: Arc::downgrade(&tracked.inner),
        }
    }

    pub(crate) fn ptr_eq(this: &Self, other: &Self) -> bool {
        Arc::ptr_eq(&this.inner, &other.inner)
    }

    pub(crate) fn strong_count(this: &Self) -> usize {
        Arc::strong_count(&this.inner)
    }

    #[cfg(all(test, mongodb_internal_tracking_arc))]
    #[allow(unused)]
    pub(crate) fn print_live(tracked: &Self) {
        let current: Vec<_> = tracked
            .inner
            .clones
            .lock()
            .unwrap()
            .values()
            .cloned()
            .collect();
        for mut bt in current {
            bt.resolve();
            println!("{:?}", bt);
        }
    }
}

impl<T> Clone for TrackingArc<T> {
    fn clone(&self) -> Self {
        #[cfg(all(test, mongodb_internal_tracking_arc))]
        let clone_id = {
            let bt = backtrace::Backtrace::new_unresolved();
            Some(self.inner.clones.lock().unwrap().insert(bt))
        };
        Self {
            inner: self.inner.clone(),
            #[cfg(all(test, mongodb_internal_tracking_arc))]
            clone_id,
        }
    }
}

impl<T> Drop for TrackingArc<T> {
    fn drop(&mut self) {
        #[cfg(all(test, mongodb_internal_tracking_arc))]
        if let Some(id) = &self.clone_id {
            self.inner.clones.lock().unwrap().remove(id);
        }
    }
}

impl<T> std::ops::Deref for TrackingArc<T> {
    type Target = T;
    fn deref(&self) -> &T {
        &self.inner.value
    }
}

#[cfg(feature = "in-use-encryption")]
#[derive(Debug)]
pub(crate) struct Weak<T> {
    inner: std::sync::Weak<Inner<T>>,
}

#[cfg(feature = "in-use-encryption")]
impl<T> Clone for Weak<T> {
    fn clone(&self) -> Self {
        Self {
            inner: self.inner.clone(),
        }
    }
}

#[cfg(feature = "in-use-encryption")]
impl<T> Weak<T> {
    pub(crate) fn upgrade(&self) -> Option<TrackingArc<T>> {
        self.inner.upgrade().map(|inner| {
            #[cfg(all(test, mongodb_internal_tracking_arc))]
            let clone_id = {
                let bt = backtrace::Backtrace::new_unresolved();
                Some(inner.clones.lock().unwrap().insert(bt))
            };
            TrackingArc {
                inner,
                #[cfg(all(test, mongodb_internal_tracking_arc))]
                clone_id,
            }
        })
    }
}
