use crate::Value;
use crate::caching::statistics::Statistics;
use lru::LruCache;
use std::collections::hash_map::DefaultHasher;
use std::hash::Hasher;
use std::num::NonZeroUsize;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;

type RedisCmd = Vec<u8>;
type RedisKey = Vec<u8>;

pub(crate) struct CacheCmdEntry {
    cmd: RedisCmd,
    value: Value,
}

/// CacheItem keeps information about a key's expiry time and cached response for each key, command pair.
pub(crate) struct CacheItem {
    expire_time: Instant,
    epoch: usize,
    value_list: Vec<CacheCmdEntry>,
}

type LRUCacheShard = LruCache<RedisKey, CacheItem>;

pub(crate) struct ShardedLRU {
    shards: Vec<std::sync::Mutex<LRUCacheShard>>,
    pub(crate) statistics: Arc<Statistics>,
    last_epoch: AtomicUsize,
}

impl ShardedLRU {
    const MAX_SHARD_COUNT: usize = 32;

    pub(crate) fn new(total_key_size: NonZeroUsize) -> Self {
        // If total cache size is smaller than max shard size then it won't use sharding.
        let (shard_count, shard_size) = if total_key_size.get() >= Self::MAX_SHARD_COUNT {
            (
                Self::MAX_SHARD_COUNT,
                total_key_size.get() / Self::MAX_SHARD_COUNT,
            )
        } else {
            (1, total_key_size.get())
        };

        let mut shards = Vec::with_capacity(shard_count);
        for _ in 0..shard_count {
            let shard = LruCache::new(NonZeroUsize::new(shard_size).unwrap());
            shards.push(std::sync::Mutex::new(shard));
        }
        let statistics = Arc::new(Statistics::default());
        Self {
            shards,
            statistics,
            last_epoch: AtomicUsize::new(0),
        }
    }

    /// get_shard will get MutexGuard for a shard determined by key, if lock is poisoned it'll be recovered.
    pub(crate) fn get_shard(&self, key: &[u8]) -> std::sync::MutexGuard<'_, LRUCacheShard> {
        let mut s = DefaultHasher::new();
        s.write(key);
        let lock = &self.shards[s.finish() as usize % self.shards.len()];
        lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub(crate) fn get<'a>(
        &self,
        redis_key: &'a [u8],
        redis_cmd: &'a [u8],
        epoch: usize,
    ) -> Option<Value> {
        let mut lru_cache = self.get_shard(redis_key);
        if let Some(cache_item) = lru_cache.get_mut(redis_key) {
            // If one of following conditions are true, cache item is invalid and can't be trusted to use:
            // Epoch of client is not same, it means cache item is created by another redis connection.
            // Expire time of key has been passed, value could be stale.
            let cache_item_is_invalid =
                cache_item.epoch != epoch || Instant::now() > cache_item.expire_time;
            if cache_item_is_invalid {
                self.statistics
                    .increase_invalidate(cache_item.value_list.len());
                self.statistics.increase_miss(1);
                lru_cache.pop(redis_key);
                return None;
            }
            // Found redis key in cache, but KEY,CMD combination also must be in the cache otherwise, it will be fetched from server.
            for entry in &cache_item.value_list {
                if entry.cmd == redis_cmd {
                    self.statistics.increase_hit(1);
                    return Some(entry.value.clone());
                }
            }
        }
        drop(lru_cache);
        self.statistics.increase_miss(1);
        None
    }

    pub(crate) fn insert(
        &self,
        redis_key: &[u8],
        cmd_key: &[u8],
        value: Value,
        expire_time: Instant,
        epoch: usize,
    ) {
        let mut lru_cache = self.get_shard(redis_key);
        if let Some(ch) = lru_cache.peek_mut(redis_key)
            && ch.epoch == epoch
        {
            for entry in &mut ch.value_list {
                if entry.cmd == cmd_key {
                    entry.value = value;
                    ch.expire_time = expire_time;
                    return;
                }
            }
            ch.value_list.push(CacheCmdEntry {
                cmd: cmd_key.to_vec(),
                value,
            });
            ch.expire_time = expire_time;
            return;
        }
        let _ = lru_cache.push(
            redis_key.to_vec(),
            CacheItem {
                expire_time,
                value_list: vec![CacheCmdEntry {
                    cmd: cmd_key.to_vec(),
                    value,
                }],
                epoch,
            },
        );
    }

    pub(crate) fn invalidate(&self, cache_key: &Vec<u8>) {
        // Use a separate binding for this to release the lock guard before calling increase_invalidate.
        let maybe_cache_holder = self.get_shard(cache_key).pop(cache_key);
        if let Some(cache_holder) = maybe_cache_holder {
            self.statistics
                .increase_invalidate(cache_holder.value_list.len());
        }
    }

    pub(crate) fn increase_epoch(&self) -> usize {
        self.last_epoch.fetch_add(1, Ordering::Relaxed)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::ops::Add;
    use std::time::Duration;
    static CMD_KEY: &[u8] = b"test_cmd_key".as_slice();
    static CMD_KEY_2: &[u8] = b"test_cmd_key_2".as_slice();
    static REDIS_KEY: &[u8] = b"test_redis_key".as_slice();

    #[test]
    fn test_expire() {
        let sharded_lru = ShardedLRU::new(NonZeroUsize::new(64).unwrap());

        sharded_lru.insert(
            REDIS_KEY,
            CMD_KEY,
            Value::Boolean(true),
            Instant::now().add(Duration::from_secs(10)),
            0,
        );
        assert_eq!(
            sharded_lru.get(REDIS_KEY, CMD_KEY, 0),
            Some(Value::Boolean(true))
        );
        assert_eq!(
            sharded_lru.get(REDIS_KEY, CMD_KEY_2, 0),
            None,
            "Using different cmd key must result in cache miss"
        );

        sharded_lru.insert(
            REDIS_KEY,
            CMD_KEY,
            Value::Boolean(false),
            Instant::now().add(Duration::from_millis(5)),
            0,
        );
        assert_eq!(
            sharded_lru.get(REDIS_KEY, CMD_KEY, 0),
            Some(Value::Boolean(false)),
            "Old value must be overwritten"
        );
        std::thread::sleep(Duration::from_millis(6));
        assert_eq!(
            sharded_lru.get(REDIS_KEY, CMD_KEY, 0),
            None,
            "Cache must be expired"
        );
    }

    #[test]
    fn test_different_cmd_keys() {
        let sharded_lru = ShardedLRU::new(NonZeroUsize::new(64).unwrap());

        sharded_lru.insert(
            REDIS_KEY,
            CMD_KEY,
            Value::Int(1),
            Instant::now().add(Duration::from_secs(10)),
            0,
        );
        // Second insert must override expire of the redis key.
        sharded_lru.insert(
            REDIS_KEY,
            CMD_KEY_2,
            Value::Int(2),
            Instant::now().add(Duration::from_millis(5)),
            0,
        );

        assert_eq!(sharded_lru.get(REDIS_KEY, CMD_KEY, 0), Some(Value::Int(1)));
        assert_eq!(
            sharded_lru.get(REDIS_KEY, CMD_KEY_2, 0),
            Some(Value::Int(2))
        );

        std::thread::sleep(Duration::from_millis(6));
        assert_eq!(
            sharded_lru.get(REDIS_KEY, CMD_KEY, 0),
            None,
            "Cache must be expired"
        );
        assert_eq!(
            sharded_lru.get(REDIS_KEY, CMD_KEY_2, 0),
            None,
            "Cache must be expired"
        );
    }

    #[test]
    fn test_invalidate() {
        let sharded_lru = ShardedLRU::new(NonZeroUsize::new(64).unwrap());

        sharded_lru.insert(
            REDIS_KEY,
            CMD_KEY,
            Value::Boolean(true),
            Instant::now().add(Duration::from_secs(10)),
            0,
        );
        assert_eq!(
            sharded_lru.get(REDIS_KEY, CMD_KEY, 0),
            Some(Value::Boolean(true))
        );
        assert_eq!(
            sharded_lru.get(REDIS_KEY, CMD_KEY_2, 0),
            None,
            "Using different cmd key must result in cache miss"
        );

        sharded_lru.invalidate(&REDIS_KEY.to_vec());
        assert_eq!(
            sharded_lru.get(REDIS_KEY, CMD_KEY, 0),
            None,
            "Cache must be invalidated"
        );
    }

    #[test]
    fn test_epoch_change() {
        let sharded_lru = ShardedLRU::new(NonZeroUsize::new(64).unwrap());

        let another_key = "foobar";

        sharded_lru.insert(
            REDIS_KEY,
            CMD_KEY,
            Value::Boolean(true),
            Instant::now().add(Duration::from_secs(10)),
            0,
        );
        sharded_lru.insert(
            another_key.as_bytes(),
            CMD_KEY,
            Value::Boolean(true),
            Instant::now().add(Duration::from_secs(10)),
            0,
        );
        assert_eq!(
            sharded_lru.get(REDIS_KEY, CMD_KEY, 0),
            Some(Value::Boolean(true))
        );
        assert_eq!(
            sharded_lru.get(REDIS_KEY, CMD_KEY_2, 0),
            None,
            "Using different cmd key must result in cache miss"
        );

        assert_eq!(
            sharded_lru.get(REDIS_KEY, CMD_KEY, 1),
            None,
            "Cache must be invalidated"
        );
        assert_eq!(
            sharded_lru.get(another_key.as_bytes(), CMD_KEY, 1),
            None,
            "Cache must be invalidated"
        );
    }
}
