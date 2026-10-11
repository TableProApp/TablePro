#[cfg(feature = "aio")]
use futures_util::{
    Stream, StreamExt,
    future::BoxFuture,
    task::{Context, Poll},
};
#[cfg(feature = "aio")]
use std::pin::Pin;
#[cfg(feature = "cache-aio")]
use std::time::Duration;
use std::{fmt, io::Write};

use crate::pipeline::Pipeline;
use crate::types::{FromRedisValue, RedisResult, RedisWrite, ToRedisArgs, from_redis_value};
use crate::{ParsingError, connection::ConnectionLike};

/// An argument to a redis command
#[derive(Clone, PartialEq, Debug)]
#[non_exhaustive]
pub enum Arg<D> {
    /// A normal argument
    Simple(D),
    /// A cursor argument created from `cursor_arg()`
    Cursor,
}

/// CommandCacheConfig is used to define caching behaviour of individual commands.
/// # Example
/// ```rust
/// use std::time::Duration;
/// use redis::{CommandCacheConfig, Cmd};
///
/// let ttl = Duration::from_secs(120); // 2 minutes TTL
/// let config = CommandCacheConfig::new()
///     .set_enable_cache(true)
///     .set_client_side_ttl(ttl);
/// let command = Cmd::new().arg("GET").arg("key").set_cache_config(config);
/// ```
#[cfg(feature = "cache-aio")]
#[cfg_attr(docsrs, doc(cfg(feature = "cache-aio")))]
#[derive(Clone, Debug)]
pub struct CommandCacheConfig {
    pub(crate) enable_cache: bool,
    pub(crate) client_side_ttl: Option<Duration>,
}

#[cfg(feature = "cache-aio")]
impl CommandCacheConfig {
    /// Creates new CommandCacheConfig with enable_cache as true and without client_side_ttl.
    pub fn new() -> Self {
        Self {
            enable_cache: true,
            client_side_ttl: None,
        }
    }

    /// Sets whether the cache should be enabled or not.
    /// Disabling cache for specific command when using [crate::caching::CacheMode::All] will not work.
    pub fn set_enable_cache(mut self, enable_cache: bool) -> Self {
        self.enable_cache = enable_cache;
        self
    }

    /// Sets custom client side time to live (TTL).
    pub fn set_client_side_ttl(mut self, client_side_ttl: Duration) -> Self {
        self.client_side_ttl = Some(client_side_ttl);
        self
    }
}
#[cfg(feature = "cache-aio")]
impl Default for CommandCacheConfig {
    fn default() -> Self {
        Self::new()
    }
}

/// Represents redis commands.
#[derive(Clone)]
pub struct Cmd {
    pub(crate) data: Vec<u8>,
    // Arg::Simple contains the offset that marks the end of the argument
    args: Vec<Arg<usize>>,
    cursor: Option<u64>,
    // If it's true command's response won't be read from socket. Useful for Pub/Sub.
    no_response: bool,
    pub(crate) skip_concurrency_limit: bool,
    #[cfg(feature = "cache-aio")]
    cache: Option<CommandCacheConfig>,
}

impl std::fmt::Debug for Cmd {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut debug_struct = f.debug_struct("Cmd");
        debug_struct
            .field("data", &String::from_utf8_lossy(&self.data).as_ref())
            .field("args", &self.args)
            .field("cursor", &self.cursor)
            .field("no_response", &self.no_response);

        #[cfg(feature = "cache-aio")]
        debug_struct.field("cache", &self.cache);

        debug_struct.finish()
    }
}

/// Represents a redis iterator.
pub struct Iter<'a, T: FromRedisValue> {
    iter: CheckedIter<'a, T>,
}
impl<T: FromRedisValue> Iterator for Iter<'_, T> {
    type Item = RedisResult<T>;

    #[inline]
    fn next(&mut self) -> Option<RedisResult<T>> {
        self.iter.next()
    }
}

/// Represents a safe(r) redis iterator.
struct CheckedIter<'a, T: FromRedisValue> {
    batch: std::vec::IntoIter<Result<T, ParsingError>>,
    con: &'a mut (dyn ConnectionLike + 'a),
    cmd: Cmd,
}

impl<T: FromRedisValue> Iterator for CheckedIter<'_, T> {
    type Item = RedisResult<T>;

    #[inline]
    fn next(&mut self) -> Option<RedisResult<T>> {
        // we need to do this in a loop until we produce at least one item
        // or we find the actual end of the iteration.  This is necessary
        // because with filtering an iterator it is possible that a whole
        // chunk is not matching the pattern and thus yielding empty results.
        loop {
            if let Some(value) = self.batch.next() {
                return Some(value.map_err(|err| err.into()));
            }

            if self.cmd.cursor? == 0 {
                return None;
            }

            let (cursor, batch) = match self
                .con
                .req_packed_command(&self.cmd.get_packed_command())
                .and_then(|val| Ok(from_redis_value::<(u64, _)>(val)?))
            {
                Ok((cursor, values)) => (cursor, T::from_each_redis_values(values)),
                Err(e) => return Some(Err(e)),
            };

            self.cmd.cursor = Some(cursor);
            self.batch = batch.into_iter();
        }
    }
}

#[cfg(feature = "aio")]
use crate::aio::ConnectionLike as AsyncConnection;

/// The inner future of AsyncIter
#[cfg(feature = "aio")]
struct AsyncIterInner<'a, T: FromRedisValue + 'a> {
    batch: std::vec::IntoIter<Result<T, ParsingError>>,
    con: &'a mut (dyn AsyncConnection + Send + 'a),
    cmd: Cmd,
}

/// Represents the state of AsyncIter
#[cfg(feature = "aio")]
enum IterOrFuture<'a, T: FromRedisValue + 'a> {
    Iter(AsyncIterInner<'a, T>),
    Future(BoxFuture<'a, (AsyncIterInner<'a, T>, Option<RedisResult<T>>)>),
    Empty,
}

/// Represents a redis iterator that can be used with async connections.
#[cfg(feature = "aio")]
pub struct AsyncIter<'a, T: FromRedisValue + 'a> {
    inner: IterOrFuture<'a, T>,
}

#[cfg(feature = "aio")]
impl<'a, T: FromRedisValue + 'a> AsyncIterInner<'a, T> {
    async fn next_item(&mut self) -> Option<RedisResult<T>> {
        // we need to do this in a loop until we produce at least one item
        // or we find the actual end of the iteration.  This is necessary
        // because with filtering an iterator it is possible that a whole
        // chunk is not matching the pattern and thus yielding empty results.
        loop {
            if let Some(v) = self.batch.next() {
                return Some(v.map_err(|err| err.into()));
            }

            if self.cmd.cursor? == 0 {
                return None;
            }

            let (cursor, batch) = match self
                .con
                .req_packed_command(&self.cmd)
                .await
                .and_then(|val| Ok(from_redis_value::<(u64, _)>(val)?))
            {
                Ok((cursor, items)) => (cursor, T::from_each_redis_values(items)),
                Err(e) => return Some(Err(e)),
            };

            self.cmd.cursor = Some(cursor);
            self.batch = batch.into_iter();
        }
    }
}

#[cfg(feature = "aio")]
impl<'a, T: FromRedisValue + 'a + Unpin + Send> AsyncIter<'a, T> {
    /// ```rust,no_run
    /// # use redis::AsyncCommands;
    /// # async fn scan_set() -> redis::RedisResult<()> {
    /// # let client = redis::Client::open("redis://127.0.0.1/")?;
    /// # let mut con = client.get_multiplexed_async_connection().await?;
    /// let _: () = con.sadd("my_set", 42i32).await?;
    /// let _: () = con.sadd("my_set", 43i32).await?;
    /// let mut iter: redis::AsyncIter<i32> = con.sscan("my_set").await?;
    /// while let Some(element) = iter.next_item().await {
    ///     let element = element?;
    ///     assert!(element == 42 || element == 43);
    /// }
    /// # Ok(())
    /// # }
    /// ```
    #[inline]
    pub async fn next_item(&mut self) -> Option<RedisResult<T>> {
        StreamExt::next(self).await
    }
}

#[cfg(feature = "aio")]
impl<'a, T: FromRedisValue + Unpin + Send + 'a> Stream for AsyncIter<'a, T> {
    type Item = RedisResult<T>;

    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let this = self.get_mut();
        let inner = std::mem::replace(&mut this.inner, IterOrFuture::Empty);
        match inner {
            IterOrFuture::Iter(mut iter) => {
                let fut = async move {
                    let next_item = iter.next_item().await;
                    (iter, next_item)
                };
                this.inner = IterOrFuture::Future(Box::pin(fut));
                Pin::new(this).poll_next(cx)
            }
            IterOrFuture::Future(mut fut) => match fut.as_mut().poll(cx) {
                Poll::Pending => {
                    this.inner = IterOrFuture::Future(fut);
                    Poll::Pending
                }
                Poll::Ready((iter, value)) => {
                    this.inner = IterOrFuture::Iter(iter);

                    Poll::Ready(value)
                }
            },
            IterOrFuture::Empty => unreachable!(),
        }
    }
}

fn countdigits(mut v: usize) -> usize {
    let mut result = 1;
    loop {
        if v < 10 {
            return result;
        }
        if v < 100 {
            return result + 1;
        }
        if v < 1000 {
            return result + 2;
        }
        if v < 10000 {
            return result + 3;
        }

        v /= 10000;
        result += 4;
    }
}

#[inline]
fn bulklen(len: usize) -> usize {
    1 + countdigits(len) + 2 + len + 2
}

fn args_len<'a, I>(args: I, cursor: u64) -> usize
where
    I: IntoIterator<Item = Arg<&'a [u8]>> + ExactSizeIterator,
{
    let mut totlen = 1 + countdigits(args.len()) + 2;
    for item in args {
        totlen += bulklen(match item {
            Arg::Cursor => countdigits(cursor as usize),
            Arg::Simple(val) => val.len(),
        });
    }
    totlen
}

pub(crate) fn cmd_len(cmd: &Cmd) -> usize {
    args_len(cmd.args_iter(), cmd.cursor.unwrap_or(0))
}

fn encode_command<'a, I>(args: I, cursor: u64) -> Vec<u8>
where
    I: IntoIterator<Item = Arg<&'a [u8]>> + Clone + ExactSizeIterator,
{
    let mut cmd = Vec::new();
    write_command_to_vec(&mut cmd, args, cursor);
    cmd
}

fn write_command_to_vec<'a, I>(cmd: &mut Vec<u8>, args: I, cursor: u64)
where
    I: IntoIterator<Item = Arg<&'a [u8]>> + Clone + ExactSizeIterator,
{
    let totlen = args_len(args.clone(), cursor);

    cmd.reserve(totlen);

    write_command(cmd, args, cursor);
}

fn write_command<'a, I>(cmd: &mut Vec<u8>, args: I, cursor: u64)
where
    I: IntoIterator<Item = Arg<&'a [u8]>> + Clone + ExactSizeIterator,
{
    let mut buf = ::itoa::Buffer::new();

    cmd.extend_from_slice(b"*");
    cmd.extend_from_slice(buf.format(args.len()).as_bytes());
    cmd.extend_from_slice(b"\r\n");

    let mut cursor_bytes = itoa::Buffer::new();
    for item in args {
        let bytes = match item {
            Arg::Cursor => cursor_bytes.format(cursor).as_bytes(),
            Arg::Simple(val) => val,
        };

        cmd.extend_from_slice(b"$");
        cmd.extend_from_slice(buf.format(bytes.len()).as_bytes());
        cmd.extend_from_slice(b"\r\n");

        cmd.extend_from_slice(bytes);
        cmd.extend_from_slice(b"\r\n");
    }
}

impl RedisWrite for Cmd {
    fn write_arg(&mut self, arg: &[u8]) {
        self.data.extend_from_slice(arg);
        self.args.push(Arg::Simple(self.data.len()));
    }

    fn write_arg_fmt(&mut self, arg: impl fmt::Display) {
        write!(self.data, "{arg}").unwrap();
        self.args.push(Arg::Simple(self.data.len()));
    }

    fn writer_for_next_arg(&mut self) -> impl Write + '_ {
        struct CmdBufferedArgGuard<'a>(&'a mut Cmd);
        impl Drop for CmdBufferedArgGuard<'_> {
            fn drop(&mut self) {
                self.0.args.push(Arg::Simple(self.0.data.len()));
            }
        }
        impl Write for CmdBufferedArgGuard<'_> {
            fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
                self.0.data.extend_from_slice(buf);
                Ok(buf.len())
            }

            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }

        CmdBufferedArgGuard(self)
    }

    fn reserve_space_for_args(&mut self, additional: impl IntoIterator<Item = usize>) {
        let mut capacity = 0;
        let mut args = 0;
        for add in additional {
            capacity += add;
            args += 1;
        }
        self.data.reserve(capacity);
        self.args.reserve(args);
    }

    #[cfg(feature = "bytes")]
    fn bufmut_for_next_arg(&mut self, capacity: usize) -> impl bytes::BufMut + '_ {
        self.data.reserve(capacity);
        struct CmdBufferedArgGuard<'a>(&'a mut Cmd);
        impl Drop for CmdBufferedArgGuard<'_> {
            fn drop(&mut self) {
                self.0.args.push(Arg::Simple(self.0.data.len()));
            }
        }
        unsafe impl bytes::BufMut for CmdBufferedArgGuard<'_> {
            fn remaining_mut(&self) -> usize {
                self.0.data.remaining_mut()
            }

            unsafe fn advance_mut(&mut self, cnt: usize) {
                unsafe {
                    self.0.data.advance_mut(cnt);
                }
            }

            fn chunk_mut(&mut self) -> &mut bytes::buf::UninitSlice {
                self.0.data.chunk_mut()
            }

            // Vec specializes these methods, so we do too
            fn put<T: bytes::buf::Buf>(&mut self, src: T)
            where
                Self: Sized,
            {
                self.0.data.put(src);
            }

            fn put_slice(&mut self, src: &[u8]) {
                self.0.data.put_slice(src);
            }

            fn put_bytes(&mut self, val: u8, cnt: usize) {
                self.0.data.put_bytes(val, cnt);
            }
        }

        CmdBufferedArgGuard(self)
    }
}

impl Default for Cmd {
    fn default() -> Self {
        Self::new()
    }
}

/// A command acts as a builder interface to creating encoded redis
/// requests.  This allows you to easily assemble a packed command
/// by chaining arguments together.
///
/// Basic example:
///
/// ```rust
/// redis::Cmd::new().arg("SET").arg("my_key").arg(42);
/// ```
///
/// There is also a helper function called `cmd` which makes it a
/// tiny bit shorter:
///
/// ```rust
/// redis::cmd("SET").arg("my_key").arg(42);
/// ```
///
/// Because Rust currently does not have an ideal system
/// for lifetimes of temporaries, sometimes you need to hold on to
/// the initially generated command:
///
/// ```rust,no_run
/// # let client = redis::Client::open("redis://127.0.0.1/").unwrap();
/// # let mut con = client.get_connection().unwrap();
/// let mut cmd = redis::cmd("SMEMBERS");
/// let mut iter : redis::Iter<i32> = cmd.arg("my_set").clone().iter(&mut con).unwrap();
/// ```
impl Cmd {
    /// Creates a new empty command.
    pub fn new() -> Self {
        Self {
            data: vec![],
            args: vec![],
            cursor: None,
            no_response: false,
            skip_concurrency_limit: false,
            #[cfg(feature = "cache-aio")]
            cache: None,
        }
    }

    /// Creates a new empty command, with at least the requested capacity.
    pub fn with_capacity(arg_count: usize, size_of_data: usize) -> Self {
        Self {
            data: Vec::with_capacity(size_of_data),
            args: Vec::with_capacity(arg_count),
            cursor: None,
            no_response: false,
            skip_concurrency_limit: false,
            #[cfg(feature = "cache-aio")]
            cache: None,
        }
    }

    /// Get the capacities for the internal buffers.
    #[cfg(test)]
    #[allow(dead_code)]
    pub(crate) fn capacity(&self) -> (usize, usize) {
        (self.args.capacity(), self.data.capacity())
    }

    /// Clears the command, resetting it completely.
    ///
    /// This is equivalent to [`Cmd::new`], except the buffer capacity is kept.
    ///
    /// # Examples
    ///
    /// ```rust,no_run
    /// # use redis::{Client, Cmd};
    /// # let client = Client::open("redis://127.0.0.1/").unwrap();
    /// # let mut con = client.get_connection().expect("Failed to connect to Redis");
    /// let mut cmd = Cmd::new();
    /// cmd.arg("SET").arg("foo").arg("42");
    /// cmd.query::<()>(&mut con).expect("Query failed");
    /// cmd.clear();
    /// // This reuses the allocations of the previous command
    /// cmd.arg("SET").arg("bar").arg("42");
    /// cmd.query::<()>(&mut con).expect("Query failed");
    /// ```
    pub fn clear(&mut self) {
        self.data.clear();
        self.args.clear();
        self.cursor = None;
        self.no_response = false;
        self.skip_concurrency_limit = false;
        #[cfg(feature = "cache-aio")]
        {
            self.cache = None;
        }
    }

    /// Appends an argument to the command.  The argument passed must
    /// be a type that implements `ToRedisArgs`.  Most primitive types as
    /// well as vectors of primitive types implement it.
    ///
    /// For instance all of the following are valid:
    ///
    /// ```rust,no_run
    /// # let client = redis::Client::open("redis://127.0.0.1/").unwrap();
    /// # let mut con = client.get_connection().unwrap();
    /// redis::cmd("SET").arg(&["my_key", "my_value"]);
    /// redis::cmd("SET").arg("my_key").arg(42);
    /// redis::cmd("SET").arg("my_key").arg(b"my_value");
    /// ```
    #[inline]
    pub fn arg<T: ToRedisArgs>(&mut self, arg: T) -> &mut Self {
        arg.write_redis_args(self);
        self
    }

    /// Takes the command out of the mutable reference and returns it as a value
    ///
    /// The referenced command is left empty.
    pub fn take(&mut self) -> Self {
        std::mem::take(self)
    }

    /// Works similar to `arg` but adds a cursor argument.
    ///
    /// This is always an integer and also flips the command implementation to support a
    /// different mode for the iterators where the iterator will ask for
    /// another batch of items when the local data is exhausted.
    /// Calling this function more than once will overwrite the previous cursor with the latest set value.
    ///
    /// ```rust,no_run
    /// # let client = redis::Client::open("redis://127.0.0.1/").unwrap();
    /// # let mut con = client.get_connection().unwrap();
    /// let mut cmd = redis::cmd("SSCAN");
    /// let mut iter : redis::Iter<isize> =
    ///     cmd.arg("my_set").cursor_arg(0).clone().iter(&mut con).unwrap();
    /// for x in iter {
    ///     // do something with the item
    /// }
    /// ```
    #[inline]
    pub fn cursor_arg(&mut self, cursor: u64) -> &mut Self {
        self.cursor = Some(cursor);
        self.args.push(Arg::Cursor);
        self
    }

    /// Returns the packed command as a byte vector.
    ///
    /// This is a wrapper around [`write_packed_command`] that creates a [`Vec`] to write to.
    ///
    /// [`write_packed_command`]: Self::write_packed_command
    #[inline]
    pub fn get_packed_command(&self) -> Vec<u8> {
        let mut cmd = Vec::new();
        if self.is_empty() {
            return cmd;
        }
        self.write_packed_command(&mut cmd);
        cmd
    }

    /// Writes the packed command to `dst`.
    ///
    /// This will *append* the packed command.
    ///
    /// See also [`get_packed_command`].
    ///
    /// [`get_packed_command`]: Self::get_packed_command.
    #[inline]
    pub fn write_packed_command(&self, dst: &mut Vec<u8>) {
        write_command_to_vec(dst, self.args_iter(), self.cursor.unwrap_or(0));
    }

    pub(crate) fn write_packed_command_preallocated(&self, cmd: &mut Vec<u8>) {
        write_command(cmd, self.args_iter(), self.cursor.unwrap_or(0));
    }

    /// Returns true if the command is in scan mode.
    #[inline]
    pub fn in_scan_mode(&self) -> bool {
        self.cursor.is_some()
    }

    /// Sends the command as query to the connection and converts the
    /// result to the target redis value.  This is the general way how
    /// you can retrieve data.
    #[inline]
    pub fn query<T: FromRedisValue>(&self, con: &mut dyn ConnectionLike) -> RedisResult<T> {
        match con.req_command(self) {
            Ok(val) => Ok(from_redis_value(val.extract_error()?)?),
            Err(e) => Err(e),
        }
    }

    /// Async version of `query`.
    #[inline]
    #[cfg(feature = "aio")]
    pub async fn query_async<T: FromRedisValue>(
        &self,
        con: &mut impl crate::aio::ConnectionLike,
    ) -> RedisResult<T> {
        let val = con.req_packed_command(self).await?;
        Ok(from_redis_value(val.extract_error()?)?)
    }

    /// Sets the cursor and converts the passed value to a batch used by the
    /// iterators.
    fn set_cursor_and_get_batch<T: FromRedisValue>(
        &mut self,
        value: crate::Value,
    ) -> RedisResult<Vec<Result<T, ParsingError>>> {
        let (cursor, values) = if value.looks_like_cursor() {
            let (cursor, values) = from_redis_value::<(u64, _)>(value)?;
            (cursor, values)
        } else {
            (0, from_redis_value(value)?)
        };

        self.cursor = Some(cursor);

        Ok(T::from_each_redis_values(values))
    }

    /// Similar to `query()` but returns an iterator over the items of the
    /// bulk result or iterator.  In normal mode this is not in any way more
    /// efficient than just querying into a `Vec<T>` as it's internally
    /// implemented as buffering into a vector.  This however is useful when
    /// `cursor_arg` was used in which case the iterator will query for more
    /// items until the server side cursor is exhausted.
    ///
    /// This is useful for commands such as `SSCAN`, `SCAN` and others.
    ///
    /// One speciality of this function is that it will check if the response
    /// looks like a cursor or not and always just looks at the payload.
    /// This way you can use the function the same for responses in the
    /// format of `KEYS` (just a list) as well as `SSCAN` (which returns a
    /// tuple of cursor and list).
    #[inline]
    pub fn iter<T: FromRedisValue>(
        mut self,
        con: &mut dyn ConnectionLike,
    ) -> RedisResult<Iter<'_, T>> {
        let rv = con.req_command(&self)?;

        let batch = self.set_cursor_and_get_batch(rv)?;

        Ok(Iter {
            iter: CheckedIter {
                batch: batch.into_iter(),
                con,
                cmd: self,
            },
        })
    }

    /// Similar to `iter()` but returns an AsyncIter over the items of the
    /// bulk result or iterator.  A [futures::Stream](https://docs.rs/futures/0.3.3/futures/stream/trait.Stream.html)
    /// is implemented on AsyncIter. In normal mode this is not in any way more
    /// efficient than just querying into a `Vec<T>` as it's internally
    /// implemented as buffering into a vector.  This however is useful when
    /// `cursor_arg` was used in which case the stream will query for more
    /// items until the server side cursor is exhausted.
    ///
    /// This is useful for commands such as `SSCAN`, `SCAN` and others in async contexts.
    ///
    /// One speciality of this function is that it will check if the response
    /// looks like a cursor or not and always just looks at the payload.
    /// This way you can use the function the same for responses in the
    /// format of `KEYS` (just a list) as well as `SSCAN` (which returns a
    /// tuple of cursor and list).
    #[cfg(feature = "aio")]
    #[inline]
    pub async fn iter_async<'a, T: FromRedisValue + 'a>(
        mut self,
        con: &'a mut (dyn AsyncConnection + Send),
    ) -> RedisResult<AsyncIter<'a, T>> {
        let rv = con.req_packed_command(&self).await?;

        let batch = self.set_cursor_and_get_batch(rv)?;

        Ok(AsyncIter {
            inner: IterOrFuture::Iter(AsyncIterInner {
                batch: batch.into_iter(),
                con,
                cmd: self,
            }),
        })
    }

    /// This is an alternative to `query`` that can be used if you want to be able to handle a
    /// command's success or failure but don't care about the command's response. For example,
    /// this is useful for "SET" commands for which the response's content is not important.
    /// It avoids the need to define generic bounds for ().
    #[inline]
    pub fn exec(&self, con: &mut dyn ConnectionLike) -> RedisResult<()> {
        self.query::<()>(con)
    }

    /// This is an alternative to `query_async` that can be used if you want to be able to handle a
    /// command's success or failure but don't care about the command's response. For example,
    /// this is useful for "SET" commands for which the response's content is not important.
    /// It avoids the need to define generic bounds for ().
    #[cfg(feature = "aio")]
    pub async fn exec_async(&self, con: &mut impl crate::aio::ConnectionLike) -> RedisResult<()> {
        self.query_async::<()>(con).await
    }

    /// Returns an iterator over the arguments in this command (including the command name itself)
    pub fn args_iter(&self) -> impl Clone + ExactSizeIterator<Item = Arg<&[u8]>> {
        let mut prev = 0;
        self.args.iter().map(move |arg| match *arg {
            Arg::Simple(i) => {
                let arg = Arg::Simple(&self.data[prev..i]);
                prev = i;
                arg
            }

            Arg::Cursor => Arg::Cursor,
        })
    }

    // Get a reference to the argument at `idx`
    #[cfg(any(feature = "cluster", feature = "cache-aio"))]
    pub(crate) fn arg_idx(&self, idx: usize) -> Option<&[u8]> {
        if idx >= self.args.len() {
            return None;
        }

        let start = if idx == 0 {
            0
        } else {
            match self.args[idx - 1] {
                Arg::Simple(n) => n,
                _ => 0,
            }
        };
        let end = match self.args[idx] {
            Arg::Simple(n) => n,
            _ => 0,
        };
        if start == 0 && end == 0 {
            return None;
        }
        Some(&self.data[start..end])
    }

    /// Client won't read and wait for results. Currently only used for Pub/Sub commands in RESP3.
    ///
    /// This is mostly set internally. The user can set it if they know that a certain command doesn't return a response, or if they use an async connection and don't want to wait for the server response.
    /// For sync connections, setting this wrongly can affect the connection's correctness, and should be avoided.
    #[inline]
    pub fn set_no_response(&mut self, nr: bool) -> &mut Self {
        self.no_response = nr;
        self
    }

    /// Check whether command's result will be waited for.
    #[inline]
    pub fn is_no_response(&self) -> bool {
        self.no_response
    }

    /// Changes caching behaviour for this specific command.
    #[cfg(feature = "cache-aio")]
    #[cfg_attr(docsrs, doc(cfg(feature = "cache-aio")))]
    pub fn set_cache_config(&mut self, command_cache_config: CommandCacheConfig) -> &mut Self {
        self.cache = Some(command_cache_config);
        self
    }

    #[cfg(feature = "cache-aio")]
    #[inline]
    pub(crate) fn get_cache_config(&self) -> &Option<CommandCacheConfig> {
        &self.cache
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.args.is_empty()
    }
}

/// Shortcut function to creating a command with a single argument.
///
/// The first argument of a redis command is always the name of the command
/// which needs to be a string.  This is the recommended way to start a
/// command pipe.
///
/// ```rust
/// redis::cmd("PING");
/// ```
pub fn cmd(name: &str) -> Cmd {
    let mut rv = Cmd::new();
    rv.arg(name);
    rv
}

/// Packs a bunch of commands into a request.
///
/// This is generally a quite useless function as this functionality is
/// nicely wrapped through the `Cmd` object, but in some cases it can be
/// useful.  The return value of this can then be send to the low level
/// `ConnectionLike` methods.
///
/// Example:
///
/// ```rust
/// # use redis::ToRedisArgs;
/// let mut args = vec![];
/// args.extend("SET".to_redis_args());
/// args.extend("my_key".to_redis_args());
/// args.extend(42.to_redis_args());
/// let cmd = redis::pack_command(&args);
/// assert_eq!(cmd, b"*3\r\n$3\r\nSET\r\n$6\r\nmy_key\r\n$2\r\n42\r\n".to_vec());
/// ```
pub fn pack_command(args: &[Vec<u8>]) -> Vec<u8> {
    encode_command(args.iter().map(|x| Arg::Simple(&x[..])), 0)
}

/// Shortcut for creating a new pipeline.
pub fn pipe() -> Pipeline {
    Pipeline::new()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(feature = "bytes")]
    use bytes::BufMut;

    fn args_iter_to_str(cmd: &Cmd) -> Vec<String> {
        cmd.args_iter()
            .map(|arg| match arg {
                Arg::Simple(bytes) => String::from_utf8(bytes.to_vec()).unwrap(),
                Arg::Cursor => "CURSOR".to_string(),
            })
            .collect()
    }

    fn assert_arg_equality(c1: &Cmd, c2: &Cmd) {
        let v1: Vec<_> = c1.args_iter().collect::<Vec<_>>();
        let v2: Vec<_> = c2.args_iter().collect::<Vec<_>>();
        assert_eq!(
            v1,
            v2,
            "{:?} - {:?}",
            args_iter_to_str(c1),
            args_iter_to_str(c2)
        );
    }

    fn assert_practical_equivalent(c1: Cmd, c2: Cmd) {
        assert_eq!(c1.get_packed_command(), c2.get_packed_command());
        assert_arg_equality(&c1, &c2);
    }

    #[test]
    fn test_cmd_packed_command_simple_args() {
        let args: &[&[u8]] = &[b"phone", b"barz"];
        let mut cmd = cmd("key");
        cmd.write_arg_fmt("value");
        cmd.arg(42).arg(args);

        let packed_command = cmd.get_packed_command();
        assert_eq!(cmd_len(&cmd), packed_command.len());
        assert_eq!(
            packed_command,
            b"*5\r\n$3\r\nkey\r\n$5\r\nvalue\r\n$2\r\n42\r\n$5\r\nphone\r\n$4\r\nbarz\r\n",
            "{}",
            String::from_utf8(packed_command.clone()).unwrap()
        );
        let args_vec: Vec<&[u8]> = vec![b"key", b"value", b"42", b"phone", b"barz"];
        let args_vec: Vec<_> = args_vec.into_iter().map(Arg::Simple).collect();
        assert_eq!(cmd.args_iter().collect::<Vec<_>>(), args_vec);
    }

    #[test]
    fn test_cmd_packed_command_with_cursor() {
        let args: &[&[u8]] = &[b"phone", b"barz"];
        let mut cmd = cmd("key");
        cmd.arg("value").arg(42).arg(args).cursor_arg(512);

        let packed_command = cmd.get_packed_command();
        assert_eq!(cmd_len(&cmd), packed_command.len());
        assert_eq!(
            packed_command,
            b"*6\r\n$3\r\nkey\r\n$5\r\nvalue\r\n$2\r\n42\r\n$5\r\nphone\r\n$4\r\nbarz\r\n$3\r\n512\r\n",
            "{}",
            String::from_utf8(packed_command.clone()).unwrap()
        );
        let args_vec: Vec<&[u8]> = vec![b"key", b"value", b"42", b"phone", b"barz"];
        let args_vec: Vec<_> = args_vec
            .into_iter()
            .map(Arg::Simple)
            .chain(std::iter::once(Arg::Cursor))
            .collect();
        assert_eq!(cmd.args_iter().collect::<Vec<_>>(), args_vec);
    }

    #[test]
    fn test_cmd_clean() {
        let mut cmd = cmd("key");
        cmd.arg("value")
            .cursor_arg(24)
            .set_no_response(true)
            .clear();

        // Everything should be reset, but the capacity should still be there
        assert!(cmd.data.is_empty());
        assert!(cmd.data.capacity() > 0);
        assert!(cmd.is_empty());
        assert!(cmd.args.capacity() > 0);
        assert_eq!(cmd.cursor, None);
        assert!(!cmd.no_response);
        assert_practical_equivalent(cmd, Cmd::new());
    }

    #[test]
    #[cfg(feature = "cache-aio")]
    fn test_cmd_clean_cache_aio() {
        let mut cmd = cmd("key");
        cmd.arg("value")
            .cursor_arg(24)
            .set_cache_config(crate::CommandCacheConfig::default())
            .set_no_response(true)
            .clear();

        // Everything should be reset, but the capacity should still be there
        assert!(cmd.data.is_empty());
        assert!(cmd.data.capacity() > 0);
        assert!(cmd.is_empty());
        assert!(cmd.args.capacity() > 0);
        assert_eq!(cmd.cursor, None);
        assert!(!cmd.no_response);
        assert!(cmd.cache.is_none());
    }

    #[test]
    fn test_cmd_writer_for_next_arg() {
        // Test that a write split across multiple calls to `write` produces the
        // same result as a single call to `write_arg`
        let mut c1 = Cmd::new();
        {
            let mut c1_writer = c1.writer_for_next_arg();
            c1_writer.write_all(b"foo").unwrap();
            c1_writer.write_all(b"bar").unwrap();
            c1_writer.flush().unwrap();
        }

        let mut c2 = Cmd::new();
        c2.write_arg(b"foobar");

        assert_practical_equivalent(c1, c2);
    }

    // Test that multiple writers to the same command produce the same
    // result as the same multiple calls to `write_arg`
    #[test]
    fn test_cmd_writer_for_next_arg_multiple() {
        let mut c1 = Cmd::new();
        {
            let mut c1_writer = c1.writer_for_next_arg();
            c1_writer.write_all(b"foo").unwrap();
            c1_writer.write_all(b"bar").unwrap();
            c1_writer.flush().unwrap();
        }
        {
            let mut c1_writer = c1.writer_for_next_arg();
            c1_writer.write_all(b"baz").unwrap();
            c1_writer.write_all(b"qux").unwrap();
            c1_writer.flush().unwrap();
        }

        let mut c2 = Cmd::new();
        c2.write_arg(b"foobar");
        c2.write_arg(b"bazqux");

        assert_practical_equivalent(c1, c2);
    }

    // Test that an "empty" write produces the equivalent to `write_arg(b"")`
    #[test]
    fn test_cmd_writer_for_next_arg_empty() {
        let mut c1 = Cmd::new();
        {
            let mut c1_writer = c1.writer_for_next_arg();
            c1_writer.flush().unwrap();
        }

        let mut c2 = Cmd::new();
        c2.write_arg(b"");

        assert_practical_equivalent(c1, c2);
    }

    #[cfg(feature = "bytes")]
    /// Test that a write split across multiple calls to `write` produces the
    /// same result as a single call to `write_arg`
    #[test]
    fn test_cmd_bufmut_for_next_arg() {
        let mut c1 = Cmd::new();
        {
            let mut c1_writer = c1.bufmut_for_next_arg(6);
            c1_writer.put_slice(b"foo");
            c1_writer.put_slice(b"bar");
        }

        let mut c2 = Cmd::new();
        c2.write_arg(b"foobar");

        assert_practical_equivalent(c1, c2);
    }

    #[cfg(feature = "bytes")]
    /// Test that multiple writers to the same command produce the same
    /// result as the same multiple calls to `write_arg`
    #[test]
    fn test_cmd_bufmut_for_next_arg_multiple() {
        let mut c1 = Cmd::new();
        {
            let mut c1_writer = c1.bufmut_for_next_arg(6);
            c1_writer.put_slice(b"foo");
            c1_writer.put_slice(b"bar");
        }
        {
            let mut c1_writer = c1.bufmut_for_next_arg(6);
            c1_writer.put_slice(b"baz");
            c1_writer.put_slice(b"qux");
        }

        let mut c2 = Cmd::new();
        c2.write_arg(b"foobar");
        c2.write_arg(b"bazqux");

        assert_practical_equivalent(c1, c2);
    }

    #[cfg(feature = "bytes")]
    /// Test that an "empty" write produces the equivalent to `write_arg(b"")`
    #[test]
    fn test_cmd_bufmut_for_next_arg_empty() {
        let mut c1 = Cmd::new();
        {
            let _c1_writer = c1.bufmut_for_next_arg(0);
        }

        let mut c2 = Cmd::new();
        c2.write_arg(b"");

        assert_practical_equivalent(c1, c2);
    }

    #[test]
    #[cfg(feature = "cluster")]
    fn test_cmd_arg_idx() {
        let mut c = Cmd::new();
        assert_eq!(c.arg_idx(0), None);

        c.arg("SET");
        assert_eq!(c.arg_idx(0), Some(&b"SET"[..]));
        assert_eq!(c.arg_idx(1), None);

        c.arg("foo").arg("42");
        assert_eq!(c.arg_idx(1), Some(&b"foo"[..]));
        assert_eq!(c.arg_idx(2), Some(&b"42"[..]));
        assert_eq!(c.arg_idx(3), None);
        assert_eq!(c.arg_idx(4), None);
    }
}
