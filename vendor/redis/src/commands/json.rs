//! Commands and types for working with the RedisJSON module.

use crate::cmd::{Cmd, cmd};
use crate::connection::ConnectionLike;
use crate::pipeline::Pipeline;
use crate::types::{
    ExistenceCheck, FromRedisValue, RedisResult, RedisWrite, ToRedisArgs, ToSingleRedisArg,
};

#[cfg(feature = "cluster")]
use crate::commands::ClusterPipeline;

use serde::ser::Serialize;

macro_rules! implement_json_commands {
    (
        $lifetime: lifetime
        $(
            $(#[$attr:meta])+
            fn $name:ident<$($tyargs:ident : $ty:ident),*>(
                $($argname:ident: $argty:ty),*) $body:block
        )*
    ) => (

        /// Implements RedisJSON commands for connection like objects.  This
        /// allows you to send commands straight to a connection or client.  It
        /// is also implemented for redis results of clients which makes for
        /// very convenient access in some basic cases.
        ///
        /// This allows you to use nicer syntax for some common operations.
        /// For instance this code:
        ///
        /// ```rust,no_run
        /// use redis::JsonCommands;
        /// use serde_json::json;
        /// # fn do_something() -> redis::RedisResult<()> {
        /// let client = redis::Client::open("redis://127.0.0.1/")?;
        /// let mut con = client.get_connection()?;
        /// redis::cmd("JSON.SET").arg("my_key").arg("$").arg(&json!({"item": 42i32}).to_string()).exec(&mut con).unwrap();
        /// assert_eq!(redis::cmd("JSON.GET").arg("my_key").arg("$").query(&mut con), Ok(String::from(r#"[{"item":42}]"#)));
        /// # Ok(()) }
        /// ```
        ///
        /// Will become this:
        ///
        /// ```rust,no_run
        /// use redis::JsonCommands;
        /// use serde_json::json;
        /// # fn do_something() -> redis::RedisResult<()> {
        /// let client = redis::Client::open("redis://127.0.0.1/")?;
        /// let mut con = client.get_connection()?;
        /// let _: () = con.json_set("my_key", "$", &json!({"item": 42i32}).to_string())?;
        /// assert_eq!(con.json_get("my_key", "$"), Ok(String::from(r#"[{"item":42}]"#)));
        /// assert_eq!(con.json_get("my_key", "$.item"), Ok(String::from(r#"[42]"#)));
        /// # Ok(()) }
        /// ```
        ///
        /// With RedisJSON commands, you have to note that all results will be wrapped
        /// in square brackets (or empty brackets if not found). If you want to deserialize it
        /// with e.g. `serde_json` you have to use `Vec<T>` for your output type instead of `T`.
        pub trait JsonCommands : ConnectionLike + Sized {
            $(
                $(#[$attr])*
                #[inline]
                #[allow(clippy::extra_unused_lifetimes, clippy::needless_lifetimes)]
                fn $name<$lifetime, $($tyargs: $ty, )* RV: FromRedisValue>(
                    &mut self $(, $argname: $argty)*) -> RedisResult<RV>
                    { Cmd::$name($($argname),*)?.query(self) }
            )*
        }

        impl Cmd {
            $(
                $(#[$attr])*
                #[allow(clippy::extra_unused_lifetimes, clippy::needless_lifetimes)]
                pub fn $name<$lifetime, $($tyargs: $ty),*>($($argname: $argty),*) -> RedisResult<Self> {
                    Ok($body)
                }
            )*
        }

        /// Implements RedisJSON commands over asynchronous connections. This
        /// allows you to send commands straight to a connection or client.
        ///
        /// This allows you to use nicer syntax for some common operations.
        /// For instance this code:
        ///
        /// ```rust,no_run
        /// use redis::JsonAsyncCommands;
        /// use serde_json::json;
        /// # async fn do_something() -> redis::RedisResult<()> {
        /// let client = redis::Client::open("redis://127.0.0.1/")?;
        /// let mut con = client.get_multiplexed_async_connection().await?;
        /// redis::cmd("JSON.SET").arg("my_key").arg("$").arg(&json!({"item": 42i32}).to_string()).exec_async(&mut con).await?;
        /// assert_eq!(redis::cmd("JSON.GET").arg("my_key").arg("$").query_async(&mut con).await, Ok(String::from(r#"[{"item":42}]"#)));
        /// # Ok(()) }
        /// ```
        ///
        /// Will become this:
        ///
        /// ```rust,no_run
        /// use redis::JsonAsyncCommands;
        /// use serde_json::json;
        /// # async fn do_something() -> redis::RedisResult<()> {
        /// use redis::Commands;
        /// let client = redis::Client::open("redis://127.0.0.1/")?;
        /// let mut con = client.get_multiplexed_async_connection().await?;
        /// let _: () = con.json_set("my_key", "$", &json!({"item": 42i32}).to_string()).await?;
        /// assert_eq!(con.json_get("my_key", "$").await, Ok(String::from(r#"[{"item":42}]"#)));
        /// assert_eq!(con.json_get("my_key", "$.item").await, Ok(String::from(r#"[42]"#)));
        /// # Ok(()) }
        /// ```
        ///
        /// With RedisJSON commands, you have to note that all results will be wrapped
        /// in square brackets (or empty brackets if not found). If you want to deserialize it
        /// with e.g. `serde_json` you have to use `Vec<T>` for your output type instead of `T`.
        ///
        #[cfg(feature = "aio")]
        pub trait JsonAsyncCommands : crate::aio::ConnectionLike + Send + Sized {
            $(
                $(#[$attr])*
                #[inline]
                #[allow(clippy::extra_unused_lifetimes, clippy::needless_lifetimes)]
                fn $name<$lifetime, $($tyargs: $ty + Send + Sync + $lifetime,)* RV>(
                    & $lifetime mut self
                    $(, $argname: $argty)*
                ) -> $crate::types::RedisFuture<'a, RV>
                where
                    RV: FromRedisValue,
                {
                    Box::pin(async move {
                        $body.query_async(self).await
                    })
                }
            )*
        }

        /// Implements RedisJSON commands for pipelines.  Unlike the regular
        /// commands trait, this returns the pipeline rather than a result
        /// directly.  Other than that it works the same however.
        impl Pipeline {
            $(
                $(#[$attr])*
                #[inline]
                #[allow(clippy::extra_unused_lifetimes, clippy::needless_lifetimes)]
                pub fn $name<$lifetime, $($tyargs: $ty),*>(
                    &mut self $(, $argname: $argty)*
                ) -> RedisResult<&mut Self> {
                    self.add_command($body);
                    Ok(self)
                }
            )*
        }

        /// Implements RedisJSON commands for cluster pipelines.  Unlike the regular
        /// commands trait, this returns the cluster pipeline rather than a result
        /// directly.  Other than that it works the same however.
        #[cfg(feature = "cluster")]
        impl ClusterPipeline {
            $(
                $(#[$attr])*
                #[inline]
                #[allow(clippy::extra_unused_lifetimes, clippy::needless_lifetimes)]
                pub fn $name<$lifetime, $($tyargs: $ty),*>(
                    &mut self $(, $argname: $argty)*
                ) -> RedisResult<&mut Self> {
                    self.add_command($body);
                    Ok(self)
                }
            )*
        }
    )
}

implement_json_commands! {
    'a

    /// Append the JSON `value` to the array at `path` after the last element in it.
    fn json_arr_append<K: ToSingleRedisArg, P: ToSingleRedisArg, V: Serialize>(key: K, path: P, value: &'a V) {
        cmd("JSON.ARRAPPEND").arg(key).arg(path).arg(serde_json::to_string(value)?).take()
    }

    /// Index array at `path`, returns first occurrence of `value`
    fn json_arr_index<K: ToSingleRedisArg, P: ToSingleRedisArg, V: Serialize>(key: K, path: P, value: &'a V) {
        cmd("JSON.ARRINDEX").arg(key).arg(path).arg(serde_json::to_string(value)?).take()
    }

    /// Same as `json_arr_index` except takes a `start` and a `stop` value, setting these to `0` will mean
    /// they make no effect on the query
    ///
    /// The default values for `start` and `stop` are `0`, so pass those in if you want them to take no effect
    fn json_arr_index_ss<K: ToSingleRedisArg, P: ToSingleRedisArg, V: Serialize>(key: K, path: P, value: &'a V, start: &'a isize, stop: &'a isize) {
        cmd("JSON.ARRINDEX").arg(key).arg(path).arg(serde_json::to_string(value)?).arg(start).arg(stop).take()
    }

    /// Inserts the JSON `value` in the array at `path` before the `index` (shifts to the right).
    ///
    /// `index` must be within the array's range.
    fn json_arr_insert<K: ToSingleRedisArg, P: ToSingleRedisArg, V: Serialize>(key: K, path: P, index: i64, value: &'a V) {
        cmd("JSON.ARRINSERT").arg(key).arg(path).arg(index).arg(serde_json::to_string(value)?).take()
    }

    /// Reports the length of the JSON Array at `path` in `key`.
    fn json_arr_len<K: ToSingleRedisArg, P: ToSingleRedisArg>(key: K, path: P) {
        cmd("JSON.ARRLEN").arg(key).arg(path).take()
    }

    /// Removes and returns an element from the `index` in the array.
    ///
    /// `index` defaults to `-1` (the end of the array).
    fn json_arr_pop<K: ToSingleRedisArg, P: ToSingleRedisArg>(key: K, path: P, index: i64) {
        cmd("JSON.ARRPOP").arg(key).arg(path).arg(index).take()
    }

    /// Trims an array so that it contains only the specified inclusive range of elements.
    ///
    /// This command is extremely forgiving and using it with out-of-range indexes will not produce an error.
    /// There are a few differences between how RedisJSON v2.0 and legacy versions handle out-of-range indexes.
    fn json_arr_trim<K: ToSingleRedisArg, P: ToSingleRedisArg>(key: K, path: P, start: i64, stop: i64) {
        cmd("JSON.ARRTRIM").arg(key).arg(path).arg(start).arg(stop).take()
    }

    /// Clears container values (Arrays/Objects), and sets numeric values to 0.
    fn json_clear<K: ToSingleRedisArg, P: ToSingleRedisArg>(key: K, path: P) {
        cmd("JSON.CLEAR").arg(key).arg(path).take()
    }

    /// Deletes a value at `path`.
    fn json_del<K: ToSingleRedisArg, P: ToSingleRedisArg>(key: K, path: P) {
        cmd("JSON.DEL").arg(key).arg(path).take()
    }

    /// Gets JSON Value at `path`.
    ///
    /// With RedisJSON commands, you have to note that all results will be wrapped
    /// in square brackets (or empty brackets if not found). If you want to deserialize it
    /// with e.g. `serde_json` you have to use `Vec<T>` for your output type instead of `T`.
    fn json_get<K: ToSingleRedisArg, P: ToRedisArgs>(key: K, path: P) {
        cmd("JSON.GET").arg(key).arg(path).take()
    }

    /// Gets JSON Values at `path`.
    ///
    /// With RedisJSON commands, you have to note that all results will be wrapped
    /// in square brackets (or empty brackets if not found). If you want to deserialize it
    /// with e.g. `serde_json` you have to use `Vec<T>` for your output type instead of `T`.
    fn json_mget<K: ToRedisArgs, P: ToSingleRedisArg>(key: K, path: P) {
        cmd("JSON.MGET").arg(key).arg(path).take()
    }

    /// Increments the number value stored at `path` by `number`.
    fn json_num_incr_by<K: ToSingleRedisArg, P: ToSingleRedisArg>(key: K, path: P, value: i64) {
        cmd("JSON.NUMINCRBY").arg(key).arg(path).arg(value).take()
    }

    /// Returns the keys in the object that's referenced by `path`.
    fn json_obj_keys<K: ToSingleRedisArg, P: ToSingleRedisArg>(key: K, path: P) {
        cmd("JSON.OBJKEYS").arg(key).arg(path).take()
    }

    /// Reports the number of keys in the JSON Object at `path` in `key`.
    fn json_obj_len<K: ToSingleRedisArg, P: ToSingleRedisArg>(key: K, path: P) {
        cmd("JSON.OBJLEN").arg(key).arg(path).take()
    }

    /// Sets the JSON Value at `path` in `key`.
    fn json_set<K: ToSingleRedisArg, P: ToSingleRedisArg, V: Serialize>(key: K, path: P, value: &'a V) {
        cmd("JSON.SET").arg(key).arg(path).arg(serde_json::to_string(value)?).take()
    }

    /// Sets the JSON Value at `path` in `key` with options.
    ///
    /// `options` carries the optional `NX`/`XX` existence check and the optional `FPHA <TYPE>` storage hint. See [`JsonSetOptions`].
    fn json_set_options<K: ToSingleRedisArg, P: ToSingleRedisArg, V: Serialize>(key: K, path: P, value: &'a V, options: &'a JsonSetOptions) {
        cmd("JSON.SET").arg(key).arg(path).arg(serde_json::to_string(value)?).arg(options).take()
    }

        /// Sets the value at the path per key, for every given tuple.
    fn json_mset<K: ToSingleRedisArg, P: ToSingleRedisArg, V: Serialize>(key_path_values: &'a [(K,P,V)]) {
        let mut cmd = cmd("JSON.MSET");

        for (key, path, value) in key_path_values {
            cmd.arg(key)
               .arg(path)
               .arg(serde_json::to_string(value)?);
        }

        cmd
    }

    /// Appends the `json-string` values to the string at `path`.
    fn json_str_append<K: ToSingleRedisArg, P: ToSingleRedisArg, V: ToSingleRedisArg>(key: K, path: P, value: V) {
        cmd("JSON.STRAPPEND").arg(key).arg(path).arg(value).take()
    }

    /// Reports the length of the JSON String at `path` in `key`.
    fn json_str_len<K: ToSingleRedisArg, P: ToSingleRedisArg>(key: K, path: P) {
        cmd("JSON.STRLEN").arg(key).arg(path).take()
    }

    /// Toggle a `boolean` value stored at `path`.
    fn json_toggle<K: ToSingleRedisArg, P: ToSingleRedisArg>(key: K, path: P) {
        cmd("JSON.TOGGLE").arg(key).arg(path).take()
    }

    /// Reports the type of JSON value at `path`.
    fn json_type<K: ToSingleRedisArg, P: ToSingleRedisArg>(key: K, path: P) {
        cmd("JSON.TYPE").arg(key).arg(path).take()
    }
}

impl<T> JsonCommands for T where T: ConnectionLike {}

#[cfg(feature = "aio")]
impl<T> JsonAsyncCommands for T where T: crate::aio::ConnectionLike + Send + Sized {}

/// Storage-precision tag for the `FPHA` form of `JSON.SET`.
///
/// Applied via [`JsonSetOptions::fpha`] instructs the server to pack any floating-point arrays in the payload using the chosen lane precision.
/// Values that fall outside the chosen type's representable range cause the server to reject the command with `ERR value out of range for <TYPE>`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[non_exhaustive]
pub enum FphaType {
    /// Server stores lanes as Google brain-float 16 (`bfloat16`).
    Bf16,
    /// Server stores lanes as IEEE-754 binary16.
    Fp16,
    /// Server stores lanes as IEEE-754 binary32.
    Fp32,
    /// Server stores lanes as IEEE-754 binary64.
    Fp64,
}

impl ToRedisArgs for FphaType {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        match self {
            Self::Bf16 => out.write_arg(b"BF16"),
            Self::Fp16 => out.write_arg(b"FP16"),
            Self::Fp32 => out.write_arg(b"FP32"),
            Self::Fp64 => out.write_arg(b"FP64"),
        }
    }
}

/// Options for the [`JSON.SET`](https://redis.io/commands/json.set) command.
///
/// Carries the optional `NX`/`XX` existence check and the optional `FPHA <TYPE>` storage hint.
///
/// # Example
/// ```rust,no_run
/// use redis::json::{FphaType, JsonSetOptions};
/// use redis::{ExistenceCheck, JsonCommands};
/// use serde_json::json;
/// # fn do_something() -> redis::RedisResult<()> {
/// let client = redis::Client::open("redis://127.0.0.1/")?;
/// let mut con = client.get_connection()?;
/// let opts = JsonSetOptions::default()
///     .conditional_set(ExistenceCheck::NX)
///     .fpha(FphaType::Fp32);
/// let _: () = con.json_set_options("my_key", "$", &[1.0_f32, 2.0], &opts)?;
/// # Ok(()) }
/// ```
#[derive(Clone, Default)]
pub struct JsonSetOptions {
    conditional_set: Option<ExistenceCheck>,
    fpha_type: Option<FphaType>,
}

impl JsonSetOptions {
    /// Apply an `NX` or `XX` existence check to the command.
    pub fn conditional_set(mut self, existence_check: ExistenceCheck) -> Self {
        self.conditional_set = Some(existence_check);
        self
    }

    /// Add an `FPHA <TYPE>` storage hint to the command.
    pub fn fpha(mut self, fpha_type: FphaType) -> Self {
        self.fpha_type = Some(fpha_type);
        self
    }
}

impl ToRedisArgs for JsonSetOptions {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        if let Some(ref conditional_set) = self.conditional_set {
            conditional_set.write_redis_args(out);
        }
        if let Some(ref ty) = self.fpha_type {
            out.write_arg(b"FPHA");
            ty.write_redis_args(out);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cmd::{Arg, Cmd, cmd};

    fn simple_args(c: &Cmd) -> Vec<Vec<u8>> {
        c.args_iter()
            .map(|a| match a {
                Arg::Simple(b) => b.to_vec(),
                Arg::Cursor => b"<CURSOR>".to_vec(),
            })
            .collect()
    }

    fn build<V: Serialize + ?Sized>(value: &V, opts: &JsonSetOptions) -> Vec<Vec<u8>> {
        let mut c = cmd("JSON.SET");
        c.arg("k")
            .arg("$")
            .arg(serde_json::to_string(value).unwrap())
            .arg(opts);
        simple_args(&c)
    }

    #[test]
    fn json_value_with_default_options_writes_serialized_document_only() {
        assert_eq!(
            build(&serde_json::json!({"a": 1}), &JsonSetOptions::default()),
            vec![
                b"JSON.SET".to_vec(),
                b"k".to_vec(),
                b"$".to_vec(),
                br#"{"a":1}"#.to_vec(),
            ],
        );
    }

    #[test]
    fn json_set_options_builder_is_order_independent() {
        let a = JsonSetOptions::default()
            .conditional_set(ExistenceCheck::NX)
            .fpha(FphaType::Fp64);
        let b = JsonSetOptions::default()
            .fpha(FphaType::Fp64)
            .conditional_set(ExistenceCheck::NX);
        assert_eq!(build(&[1.0_f64], &a), build(&[1.0_f64], &b));
    }

    #[test]
    fn fpha_type_writes_expected_bytes() {
        for (ty, expected) in [
            (FphaType::Bf16, b"BF16".as_slice()),
            (FphaType::Fp16, b"FP16".as_slice()),
            (FphaType::Fp32, b"FP32".as_slice()),
            (FphaType::Fp64, b"FP64".as_slice()),
        ] {
            let args = build(&[0.0_f32], &JsonSetOptions::default().fpha(ty));
            assert_eq!(args.len(), 6);
            assert_eq!(args[4], b"FPHA");
            assert_eq!(args[5], expected);
        }
    }

    #[test]
    fn conditional_set_nx_appends_existence_check() {
        let args = build(
            &serde_json::json!(1),
            &JsonSetOptions::default().conditional_set(ExistenceCheck::NX),
        );
        assert_eq!(args.len(), 5);
        assert_eq!(args.last().unwrap(), b"NX");
    }

    #[test]
    fn fpha_with_existence_check_orders_value_then_existence_check_then_fpha_type() {
        let args = build(
            &[1.0_f32, -0.5, 1234.5],
            &JsonSetOptions::default()
                .conditional_set(ExistenceCheck::XX)
                .fpha(FphaType::Fp32),
        );
        // [JSON.SET, k, $, <json>, XX, FPHA, FP32]
        assert_eq!(args.len(), 7);
        assert_eq!(args[3], b"[1.0,-0.5,1234.5]");
        assert_eq!(args[4], b"XX");
        assert_eq!(args[5], b"FPHA");
        assert_eq!(args[6], b"FP32");
    }

    #[test]
    fn fpha_empty_payload_still_emits_fpha_type() {
        let args = build(&[0_f32; 0], &JsonSetOptions::default().fpha(FphaType::Fp32));
        assert_eq!(args.len(), 6);
        assert_eq!(args[3], b"[]");
        assert_eq!(args[4], b"FPHA");
        assert_eq!(args[5], b"FP32");
    }

    #[test]
    fn fpha_with_matrix_emits_nested_json_and_fpha_type() {
        let matrix: &[&[f32]] = &[&[1.0, 2.5], &[3.0, 4.0]];
        let args = build(matrix, &JsonSetOptions::default().fpha(FphaType::Bf16));
        assert_eq!(args.len(), 6);
        assert_eq!(args[3], b"[[1.0,2.5],[3.0,4.0]]");
        assert_eq!(args[4], b"FPHA");
        assert_eq!(args[5], b"BF16");
    }

    #[test]
    fn json_object_properly_serialized_with_value_and_fpha_type() {
        let value = serde_json::json!({"weights": [1.0, 2.0], "bias": [0.5]});
        let args = build(&value, &JsonSetOptions::default().fpha(FphaType::Fp16));
        assert_eq!(args[3], br#"{"bias":[0.5],"weights":[1.0,2.0]}"#);
        assert_eq!(args[4], b"FPHA");
        assert_eq!(args[5], b"FP16");
    }
}
