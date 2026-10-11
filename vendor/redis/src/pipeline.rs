#![macro_use]

#[cfg(feature = "cache-aio")]
use crate::cmd::CommandCacheConfig;
use crate::cmd::{Cmd, cmd, cmd_len};
use crate::connection::ConnectionLike;
use crate::errors::ErrorKind;
use crate::types::{FromRedisValue, HashSet, RedisResult, ToRedisArgs, Value, from_redis_value};

/// Represents a redis command pipeline.
#[derive(Clone, Debug)]
pub struct Pipeline {
    pub(crate) commands: Vec<Cmd>,
    pub(crate) transaction_mode: bool,
    pub(crate) ignored_commands: HashSet<usize>,
    pub(crate) ignore_errors: bool,
}

/// A pipeline allows you to send multiple commands in one go to the
/// redis server.  API wise it's very similar to just using a command
/// but it allows multiple commands to be chained and some features such
/// as iteration are not available.
///
/// Basic example:
///
/// ```rust,no_run
/// # let client = redis::Client::open("redis://127.0.0.1/").unwrap();
/// # let mut con = client.get_connection().unwrap();
/// let ((k1, k2),) : ((i32, i32),) = redis::pipe()
///     .cmd("SET").arg("key_1").arg(42).ignore()
///     .cmd("SET").arg("key_2").arg(43).ignore()
///     .cmd("MGET").arg(&["key_1", "key_2"]).query(&mut con).unwrap();
/// ```
///
/// As you can see with `cmd` you can start a new command.  By default
/// each command produces a value but for some you can ignore them by
/// calling `ignore` on the command.  That way it will be skipped in the
/// return value which is useful for `SET` commands and others, which
/// do not have a useful return value.
impl Pipeline {
    /// Creates an empty pipeline.  For consistency with the `cmd`
    /// api a `pipe` function is provided as alias.
    pub fn new() -> Self {
        Self::with_capacity(0)
    }

    /// Creates an empty pipeline with pre-allocated capacity.
    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            commands: Vec::with_capacity(capacity),
            transaction_mode: false,
            ignored_commands: HashSet::new(),
            ignore_errors: false,
        }
    }

    /// This enables atomic mode.  In atomic mode the whole pipeline is
    /// enclosed in `MULTI`/`EXEC`.  From the user's point of view nothing
    /// changes however.  This is easier than using `MULTI`/`EXEC` yourself
    /// as the format does not change.
    ///
    /// ```rust,no_run
    /// # let client = redis::Client::open("redis://127.0.0.1/").unwrap();
    /// # let mut con = client.get_connection().unwrap();
    /// let (k1, k2) : (i32, i32) = redis::pipe()
    ///     .atomic()
    ///     .cmd("GET").arg("key_1")
    ///     .cmd("GET").arg("key_2").query(&mut con).unwrap();
    /// ```
    #[inline]
    pub fn atomic(&mut self) -> &mut Self {
        self.transaction_mode = true;
        self
    }

    /// Configures the pipeline to return partial results even if some commands fail.
    ///
    /// By default, if any command within the pipeline returns an error from the Redis server,
    /// the `query()` will only return errors, and not the results of the successful calls.
    ///
    /// When set:
    /// 1. The pipeline executes all commands.
    /// 2. `query()` returns `Ok` (unless there is a connection/IO error).
    /// 3. The results of individual commands are returned in the collection. If a command failed,
    ///    its corresponding element in the collection will be an `Err`.
    ///
    /// This allows handling partial successes where some commands succeed and others fail.
    ///
    /// **Note on ignored commands:** If you use `.ignore()` on a command, its result is discarded
    /// regardless of success or failure. If `ignore_errors()` is set, errors from ignored
    /// commands are also silently discarded and do not affect the returned result.
    ///
    /// **Note on Transactions (`atomic()`):** When used with `atomic()`, this method allows you to inspect
    /// the results of individual commands within the transaction. Redis transactions do not rollback on
    /// response errors (like `Path .path not exists`), so some commands may succeed while others fail. Using `ignore_errors()`
    /// enables you to see which commands in the transaction succeeded and which failed, rather than receiving
    /// a single aggregate error for the entire transaction.
    ///
    /// **Return Type:** When enabling this, you must use a collection of `RedisResult<T>`
    /// (e.g., `Vec<RedisResult<T>>`) or `Value` to capture both successes and failures.
    ///
    /// ```rust,no_run
    /// # let client = redis::Client::open("redis://127.0.0.1/").unwrap();
    /// # let mut con = client.get_connection().unwrap();
    /// let mut pipe = redis::pipe();
    /// pipe.set("key_a", 1)
    ///     .hset("key_a", "field", "val") // This will fail (WRONGTYPE)
    ///     .get("key_a");
    ///
    /// // Note the return type: Vec<RedisResult<i32>>
    /// let results: Vec<redis::RedisResult<i32>> = pipe
    ///     .ignore_errors()
    ///     .query(&mut con)
    ///     .unwrap(); // The query itself succeeds
    ///
    /// assert!(results[0].is_ok()); // set succeeded
    /// assert!(results[1].is_err()); // hset failed
    /// assert!(results[2].is_ok()); // get succeeded
    /// ```
    #[inline]
    pub fn ignore_errors(&mut self) -> &mut Self {
        self.ignore_errors = true;
        self
    }

    /// Returns `true` if the pipeline is in transaction mode (aka atomic mode).
    pub fn is_transaction(&self) -> bool {
        self.transaction_mode
    }

    /// Returns the encoded pipeline commands.
    pub fn get_packed_pipeline(&self) -> Vec<u8> {
        encode_pipeline(&self.commands, self.transaction_mode)
    }

    /// Returns the number of commands currently queued by the usr in the pipeline.
    ///
    /// Depending on its configuration (e.g. `atomic`), the pipeline may send more commands to the server than the returned length
    pub fn len(&self) -> usize {
        self.commands.len()
    }

    /// Returns `true` is the pipeline contains no elements.
    pub fn is_empty(&self) -> bool {
        self.commands.is_empty()
    }

    /// Executes the pipeline and fetches the return values.  Since most
    /// pipelines return different types it's recommended to use tuple
    /// matching to process the results:
    ///
    /// ```rust,no_run
    /// # let client = redis::Client::open("redis://127.0.0.1/").unwrap();
    /// # let mut con = client.get_connection().unwrap();
    /// let (k1, k2) : (i32, i32) = redis::pipe()
    ///     .cmd("SET").arg("key_1").arg(42).ignore()
    ///     .cmd("SET").arg("key_2").arg(43).ignore()
    ///     .cmd("GET").arg("key_1")
    ///     .cmd("GET").arg("key_2").query(&mut con).unwrap();
    /// ```
    ///
    /// NOTE: A Pipeline object may be reused after `query()` with all the commands as were inserted
    ///       to them. In order to clear a Pipeline object with minimal memory released/allocated,
    ///       it is necessary to call the `clear()` before inserting new commands.
    ///
    /// NOTE: This method returns a collection of results, even when there's only a single response.
    ///       Make sure to wrap single-result values in a collection. For example:
    ///
    /// ```rust,no_run
    /// # let client = redis::Client::open("redis://127.0.0.1/").unwrap();
    /// # let mut con = client.get_connection().unwrap();
    /// let (k1,): (i32,) = redis::pipe()
    ///     .cmd("SET").arg("key_1").arg(42).ignore()
    ///     .cmd("GET").arg("key_1").query(&mut con).unwrap();
    /// ```
    #[inline]
    pub fn query<T: FromRedisValue>(&self, con: &mut dyn ConnectionLike) -> RedisResult<T> {
        if !con.supports_pipelining() {
            fail!((
                ErrorKind::Client,
                "This connection does not support pipelining."
            ));
        }

        let response = if self.transaction_mode {
            con.req_packed_commands(
                &encode_pipeline(&self.commands, true),
                self.commands.len() + 1,
                1,
            )?
        } else {
            con.req_packed_commands(
                &encode_pipeline(&self.commands, false),
                0,
                self.commands.len(),
            )?
        };

        self.complete_request(response)
    }

    /// Async version of [Self::query].
    #[inline]
    #[cfg(feature = "aio")]
    pub async fn query_async<T: FromRedisValue>(
        &self,
        con: &mut impl crate::aio::ConnectionLike,
    ) -> RedisResult<T> {
        let response = if self.transaction_mode {
            con.req_packed_commands(self, self.commands.len() + 1, 1)
                .await?
        } else {
            con.req_packed_commands(self, 0, self.commands.len())
                .await?
        };

        self.complete_request(response)
    }

    /// This is an alternative to [Self::query] that can be used if you want to be able to handle a
    /// command's success or failure but don't care about the command's response. For example,
    /// this is useful for "SET" commands for which the response's content is not important.
    /// It avoids the need to define generic bounds for ().
    #[inline]
    pub fn exec(&self, con: &mut dyn ConnectionLike) -> RedisResult<()> {
        self.query::<()>(con)
    }

    /// This is an alternative to [Self::query_async] that can be used if you want to be able to handle a
    /// command's success or failure but don't care about the command's response. For example,
    /// this is useful for "SET" commands for which the response's content is not important.
    /// It avoids the need to define generic bounds for ().
    #[cfg(feature = "aio")]
    pub async fn exec_async(&self, con: &mut impl crate::aio::ConnectionLike) -> RedisResult<()> {
        self.query_async::<()>(con).await
    }

    fn complete_request<T: FromRedisValue>(&self, mut response: Vec<Value>) -> RedisResult<T> {
        let response = if self.is_transaction() {
            match response.pop() {
                Some(Value::Nil) => {
                    return Ok(from_redis_value(Value::Nil)?);
                }
                Some(Value::Array(items)) => items,
                _ => {
                    return Err((
                        ErrorKind::UnexpectedReturnType,
                        "Invalid response when parsing multi response",
                    )
                        .into());
                }
            }
        } else {
            response
        };

        self.compose_response(response)
    }
}

fn encode_pipeline(cmds: &[Cmd], atomic: bool) -> Vec<u8> {
    let mut rv = vec![];
    write_pipeline(&mut rv, cmds, atomic);
    rv
}

fn write_pipeline(rv: &mut Vec<u8>, cmds: &[Cmd], atomic: bool) {
    let cmds_len = cmds.iter().map(cmd_len).sum();

    if atomic {
        let multi = cmd("MULTI");
        let exec = cmd("EXEC");
        rv.reserve(cmd_len(&multi) + cmd_len(&exec) + cmds_len);

        multi.write_packed_command_preallocated(rv);
        for cmd in cmds {
            cmd.write_packed_command_preallocated(rv);
        }
        exec.write_packed_command_preallocated(rv);
    } else {
        rv.reserve(cmds_len);

        for cmd in cmds {
            cmd.write_packed_command_preallocated(rv);
        }
    }
}

// Macro to implement shared methods between Pipeline and ClusterPipeline
macro_rules! implement_pipeline_commands {
    ($struct_name:ident) => {
        impl $struct_name {
            /// Adds a command to the cluster pipeline.
            #[inline]
            pub fn add_command(&mut self, cmd: Cmd) -> &mut Self {
                self.commands.push(cmd);
                self
            }

            /// Starts a new command. Functions such as `arg` then become
            /// available to add more arguments to that command.
            #[inline]
            pub fn cmd(&mut self, name: &str) -> &mut Self {
                self.add_command(cmd(name))
            }

            /// Returns an iterator over all the commands currently in this pipeline
            pub fn cmd_iter(&self) -> impl Iterator<Item = &Cmd> {
                self.commands.iter()
            }

            /// Instructs the pipeline to ignore the return value of this command.
            ///
            /// On any successful result the value from this command is thrown away.
            /// This makes result processing through tuples much easier because you
            /// do not need to handle all the items you do not care about.
            /// If any command received an error from the server, no result will be ignored,
            /// so that the user could retrace which command failed.
            #[inline]
            pub fn ignore(&mut self) -> &mut Self {
                match self.commands.len() {
                    0 => true,
                    x => self.ignored_commands.insert(x - 1),
                };
                self
            }

            /// Adds an argument to the last started command. This works similar
            /// to the `arg` method of the `Cmd` object.
            ///
            /// Note that this function fails the task if executed on an empty pipeline.
            #[inline]
            pub fn arg<T: ToRedisArgs>(&mut self, arg: T) -> &mut Self {
                {
                    let cmd = self.get_last_command();
                    cmd.arg(arg);
                }
                self
            }

            /// Clear a pipeline object's internal data structure.
            ///
            /// This allows reusing a pipeline object as a clear object while performing a minimal
            /// amount of memory released/reallocated.
            #[inline]
            pub fn clear(&mut self) {
                self.commands.clear();
                self.ignored_commands.clear();
            }

            #[inline]
            fn get_last_command(&mut self) -> &mut Cmd {
                let idx = match self.commands.len() {
                    0 => panic!("No command on stack"),
                    x => x - 1,
                };
                &mut self.commands[idx]
            }

            fn filter_ignored_results(&self, resp: Vec<Value>) -> Vec<Value> {
                // Common case: nothing was `.ignore()`d, so every result is kept.
                // Return the response as-is instead of rebuilding the whole
                // `Vec<Value>` (which would reallocate and move every element).
                if self.ignored_commands.is_empty() {
                    return resp;
                }
                resp.into_iter()
                    .enumerate()
                    .filter_map(|(index, result)| {
                        (!self.ignored_commands.contains(&index)).then(|| result)
                    })
                    .collect()
            }

            fn compose_response<T: FromRedisValue>(&self, response: Vec<Value>) -> RedisResult<T> {
                if self.ignore_errors {
                    return Ok(from_redis_value(Value::Array(
                        self.filter_ignored_results(response),
                    ))?);
                }

                let server_errors: Vec<_> = response
                    .iter()
                    .enumerate()
                    .filter_map(|(index, value)| match value {
                        Value::ServerError(error) => Some((index, error.clone())),
                        _ => None,
                    })
                    .collect();

                if server_errors.is_empty() {
                    Ok(from_redis_value(
                        Value::Array(self.filter_ignored_results(response)).extract_error()?,
                    )?)
                } else {
                    Err(crate::RedisError::pipeline(server_errors))
                }
            }
        }

        impl Default for $struct_name {
            fn default() -> Self {
                Self::new()
            }
        }
    };
}

implement_pipeline_commands!(Pipeline);

// Defines caching related functions for Pipeline, ClusterPipeline isn't supported yet.
impl Pipeline {
    /// Changes caching behaviour for latest command in the pipeline.
    #[cfg(feature = "cache-aio")]
    #[cfg_attr(docsrs, doc(cfg(feature = "cache-aio")))]
    pub fn set_cache_config(&mut self, command_cache_config: CommandCacheConfig) -> &mut Self {
        let cmd = self.get_last_command();
        cmd.set_cache_config(command_cache_config);
        self
    }

    #[cfg(feature = "cluster-async")]
    pub(crate) fn into_cmd_iter(self) -> impl Iterator<Item = Cmd> {
        self.commands.into_iter()
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        ServerErrorKind,
        errors::{RedisError, Repr, ServerError},
        pipe,
    };

    use super::*;

    fn test_pipe() -> Pipeline {
        let mut pipeline = pipe();
        pipeline
            .cmd("FOO")
            .cmd("BAR")
            .ignore()
            .cmd("baz")
            .ignore()
            .cmd("barvaz");
        pipeline
    }

    fn server_error() -> Value {
        Value::ServerError(ServerError(Repr::Known {
            kind: ServerErrorKind::CrossSlot,
            detail: None,
        }))
    }

    #[test]
    fn test_pipeline_passes_values_only_from_non_ignored_commands() {
        let pipeline = test_pipe();
        let inputs = vec![Value::Int(1), Value::Int(2), Value::Int(3), Value::Okay];
        let result = pipeline.complete_request(inputs);

        let expected = vec!["1".to_string(), "OK".to_string()];
        assert_eq!(result, Ok(expected));
    }

    #[test]
    fn test_pipeline_passes_errors_from_ignored_commands() {
        let pipeline = test_pipe();
        let inputs = vec![Value::Okay, server_error(), Value::Okay, server_error()];
        let error = pipeline.compose_response::<Vec<Value>>(inputs).unwrap_err();
        let error_message = error.to_string();

        assert!(error_message.contains("Index 1"), "{error_message}");
        assert!(error_message.contains("Index 3"), "{error_message}");
    }

    #[test]
    fn test_pipeline_passes_response_from_each_commands_despite_errors() {
        let mut pipeline = test_pipe();
        let inputs = vec![Value::Okay, server_error(), Value::Okay, server_error()];
        let result = pipeline
            .ignore_errors()
            .compose_response::<Vec<RedisResult<Value>>>(inputs)
            .unwrap();

        assert_eq!(result[0], Ok::<Value, RedisError>(Value::Okay));
        assert!(
            result[1]
                .clone()
                .is_err_and(|e| e.to_string().contains("CrossSlot"))
        );
    }
}
