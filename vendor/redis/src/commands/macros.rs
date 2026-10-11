// Generate implementation for function skeleton, we use this for `AsyncTypedCommands` because we want to be able to handle having a return type specified or unspecified with a fallback
#[cfg(feature = "aio")]
macro_rules! implement_command_async {
    // If the return type is `Generic`, then we require the user to specify the return type
    (
        $lifetime: lifetime
        $(#[$attr:meta])+
        fn $name:ident<$($tyargs:ident : $ty:ident),*>(
            $($argname:ident: $argty:ty),*) $body:block Generic
    ) => {
        $(#[$attr])*
        #[inline]
        #[allow(clippy::extra_unused_lifetimes, clippy::needless_lifetimes)]
        fn $name<$lifetime, RV: FromRedisValue, $($tyargs: $ty + Send + Sync + $lifetime,)*>(
            & $lifetime mut self
            $(, $argname: $argty)*
        ) -> crate::types::RedisFuture<$lifetime, RV>
        {
            Box::pin(async move { $body.query_async(self).await })
        }
    };

    // If return type is specified in the input skeleton, then we will return it in the generated function (note match rule `$rettype:ty`)
    (
        $lifetime: lifetime
        $(#[$attr:meta])+
        fn $name:ident<$($tyargs:ident : $ty:ident),*>(
            $($argname:ident: $argty:ty),*) $body:block $rettype:ty
    ) => {
        $(#[$attr])*
        #[inline]
        #[allow(clippy::extra_unused_lifetimes, clippy::needless_lifetimes)]
        fn $name<$lifetime, $($tyargs: $ty + Send + Sync + $lifetime,)*>(
            & $lifetime mut self
            $(, $argname: $argty)*
        ) -> crate::types::RedisFuture<$lifetime, $rettype>

        {
            Box::pin(async move { $body.query_async(self).await })
        }
    };
}

macro_rules! implement_command_sync {
    // If the return type is `Generic`, then we require the user to specify the return type
    (
        $lifetime: lifetime
        $(#[$attr:meta])+
        fn $name:ident<$($tyargs:ident : $ty:ident),*>(
            $($argname:ident: $argty:ty),*) $body:block Generic
    ) => {
        $(#[$attr])*
        #[inline]
        #[allow(clippy::extra_unused_lifetimes, clippy::needless_lifetimes)]
        fn $name<$lifetime, RV: FromRedisValue, $($tyargs: $ty + Send + Sync + $lifetime,)*>(
            & $lifetime mut self
            $(, $argname: $argty)*
        ) -> RedisResult<RV>
        {
            Cmd::$name($($argname),*).query(self)
        }
    };

    // If return type is specified in the input skeleton, then we will return it in the generated function (note match rule `$rettype:ty`)
    (
        $lifetime: lifetime
        $(#[$attr:meta])+
        fn $name:ident<$($tyargs:ident : $ty:ident),*>(
            $($argname:ident: $argty:ty),*) $body:block $rettype:ty
    ) => {
        $(#[$attr])*
        #[inline]
        #[allow(clippy::extra_unused_lifetimes, clippy::needless_lifetimes)]
        fn $name<$lifetime, $($tyargs: $ty + Send + Sync + $lifetime,)*>(
            & $lifetime mut self
            $(, $argname: $argty)*
        ) -> RedisResult<$rettype>

        {
            Cmd::$name($($argname),*).query(self)
        }
    };
}

macro_rules! implement_iterators {
    ($iter:expr, $ret:ty) => {
        /// Incrementally iterate the keys space.
        #[inline]
        fn scan<RV: FromRedisValue>(&mut self) -> $ret {
            let mut c = cmd("SCAN");
            c.cursor_arg(0);
            $iter(c, self)
        }

        /// Incrementally iterate the keys space with options.
        #[inline]
        fn scan_options<RV: FromRedisValue>(&mut self, opts: ScanOptions) -> $ret {
            let mut c = cmd("SCAN");
            c.cursor_arg(0).arg(opts);
            $iter(c, self)
        }

        /// Incrementally iterate the keys space for keys matching a pattern.
        #[inline]
        fn scan_match<P: ToSingleRedisArg, RV: FromRedisValue>(&mut self, pattern: P) -> $ret {
            let mut c = cmd("SCAN");
            c.cursor_arg(0).arg("MATCH").arg(pattern);
            $iter(c, self)
        }

        /// Incrementally iterate hash fields and associated values.
        #[inline]
        fn hscan<K: ToSingleRedisArg, RV: FromRedisValue>(&mut self, key: K) -> $ret {
            let mut c = cmd("HSCAN");
            c.arg(key).cursor_arg(0);
            $iter(c, self)
        }

        /// Incrementally iterate hash fields and associated values for
        /// field names matching a pattern.
        #[inline]
        fn hscan_match<K: ToSingleRedisArg, P: ToSingleRedisArg, RV: FromRedisValue>(
            &mut self,
            key: K,
            pattern: P,
        ) -> $ret {
            let mut c = cmd("HSCAN");
            c.arg(key).cursor_arg(0).arg("MATCH").arg(pattern);
            $iter(c, self)
        }

        /// Incrementally iterate set elements.
        #[inline]
        fn sscan<K: ToSingleRedisArg, RV: FromRedisValue>(&mut self, key: K) -> $ret {
            let mut c = cmd("SSCAN");
            c.arg(key).cursor_arg(0);
            $iter(c, self)
        }

        /// Incrementally iterate set elements for elements matching a pattern.
        #[inline]
        fn sscan_match<K: ToSingleRedisArg, P: ToSingleRedisArg, RV: FromRedisValue>(
            &mut self,
            key: K,
            pattern: P,
        ) -> $ret {
            let mut c = cmd("SSCAN");
            c.arg(key).cursor_arg(0).arg("MATCH").arg(pattern);
            $iter(c, self)
        }

        /// Incrementally iterate sorted set elements.
        #[inline]
        fn zscan<K: ToSingleRedisArg, RV: FromRedisValue>(&mut self, key: K) -> $ret {
            let mut c = cmd("ZSCAN");
            c.arg(key).cursor_arg(0);
            $iter(c, self)
        }

        /// Incrementally iterate sorted set elements for elements matching a pattern.
        #[inline]
        fn zscan_match<K: ToSingleRedisArg, P: ToSingleRedisArg, RV: FromRedisValue>(
            &mut self,
            key: K,
            pattern: P,
        ) -> $ret {
            let mut c = cmd("ZSCAN");
            c.arg(key).cursor_arg(0).arg("MATCH").arg(pattern);
            $iter(c, self)
        }
    };
}

macro_rules! implement_commands {
    (
        $lifetime: lifetime
        $(
            $(#[$attr:meta])+
            fn $name:ident<$($tyargs:ident : $ty:ident),*>(
                $($argname:ident: $argty:ty),*) -> $rettype:tt $body:block
        )*
    ) =>
    (
        /// Implements common redis commands for connection like objects.
        ///
        /// This allows you to send commands straight to a connection or client.
        /// It is also implemented for redis results of clients which makes for
        /// very convenient access in some basic cases.
        ///
        /// This allows you to use nicer syntax for some common operations.
        /// For instance this code:
        ///
        /// ```rust,no_run
        /// # fn do_something() -> redis::RedisResult<()> {
        /// let client = redis::Client::open("redis://127.0.0.1/")?;
        /// let mut con = client.get_connection()?;
        /// redis::cmd("SET").arg("my_key").arg(42).exec(&mut con).unwrap();
        /// assert_eq!(redis::cmd("GET").arg("my_key").query(&mut con), Ok(42));
        /// # Ok(()) }
        /// ```
        ///
        /// Will become this:
        ///
        /// ```rust,no_run
        /// # fn do_something() -> redis::RedisResult<()> {
        /// use redis::Commands;
        /// let client = redis::Client::open("redis://127.0.0.1/")?;
        /// let mut con = client.get_connection()?;
        /// let _: () = con.set("my_key", 42)?;
        /// assert_eq!(con.get("my_key"), Ok(42));
        /// # Ok(()) }
        /// ```
        pub trait Commands : ConnectionLike+Sized {
            $(
                $(#[$attr])*
                #[inline]
                #[allow(clippy::extra_unused_lifetimes, clippy::needless_lifetimes)]
                fn $name<$lifetime, $($tyargs: $ty, )* RV: FromRedisValue>(
                    &mut self $(, $argname: $argty)*) -> RedisResult<RV>
                    { Cmd::$name($($argname),*).query(self) }
            )*

            implement_iterators! {
                |c: Cmd, this| c.iter(this),
                RedisResult<Iter<'_, RV>>
            }
        }

        impl Cmd {
            $(
                $(#[$attr])*
                #[allow(clippy::extra_unused_lifetimes, clippy::needless_lifetimes)]
                pub fn $name<$lifetime, $($tyargs: $ty),*>($($argname: $argty),*) -> Self {
                    $body
                }
            )*
        }

        /// Implements common redis commands over asynchronous connections.
        ///
        /// This allows you to send commands straight to a connection or client.
        ///
        /// This allows you to use nicer syntax for some common operations.
        /// For instance this code:
        ///
        /// ```rust,no_run
        /// use redis::AsyncCommands;
        /// # async fn do_something() -> redis::RedisResult<()> {
        /// let client = redis::Client::open("redis://127.0.0.1/")?;
        /// let mut con = client.get_multiplexed_async_connection().await?;
        /// redis::cmd("SET").arg("my_key").arg(42i32).exec_async(&mut con).await?;
        /// assert_eq!(redis::cmd("GET").arg("my_key").query_async(&mut con).await, Ok(42i32));
        /// # Ok(()) }
        /// ```
        ///
        /// Will become this:
        ///
        /// ```rust,no_run
        /// use redis::AsyncCommands;
        /// # async fn do_something() -> redis::RedisResult<()> {
        /// use redis::Commands;
        /// let client = redis::Client::open("redis://127.0.0.1/")?;
        /// let mut con = client.get_multiplexed_async_connection().await?;
        /// let _: () = con.set("my_key", 42i32).await?;
        /// assert_eq!(con.get("my_key").await, Ok(42i32));
        /// # Ok(()) }
        /// ```
        #[cfg(feature = "aio")]
        pub trait AsyncCommands : crate::aio::ConnectionLike + Send + Sized {
            $(
                $(#[$attr])*
                #[inline]
                #[allow(clippy::extra_unused_lifetimes, clippy::needless_lifetimes)]
                fn $name<$lifetime, $($tyargs: $ty + Send + Sync + $lifetime,)* RV>(
                    & $lifetime mut self
                    $(, $argname: $argty)*
                ) -> crate::types::RedisFuture<$lifetime, RV>
                where
                    RV: FromRedisValue,
                {
                    Box::pin(async move { ($body).query_async(self).await })
                }
            )*

            implement_iterators! {
                |c: Cmd, this| Box::pin(async move { c.iter_async(this).await }),
                crate::types::RedisFuture<'_, crate::cmd::AsyncIter<'_, RV>>
            }
        }

        /// Implements common redis commands.
        /// The return types are concrete and opinionated. If you want to choose the return type you should use the `Commands` trait.
        pub trait TypedCommands : ConnectionLike+Sized {
            $(
                implement_command_sync! {
                    $lifetime
                    $(#[$attr])*
                    fn $name<$($tyargs: $ty),*>(
                        $($argname: $argty),*
                    )

                    {
                        $body
                    } $rettype
                }
            )*

            implement_iterators! {
                |c: Cmd, this| c.iter(this),
                RedisResult<Iter<'_, RV>>
            }

            /// Get a value from Redis and convert it to an `Option<isize>`.
            fn get_int<K: ToSingleRedisArg>(&mut self, key: K) -> RedisResult<Option<isize>> {
                cmd("GET").arg(key).query(self)
            }

            /// Get values from Redis and convert them to `Option<isize>`s.
            fn mget_ints<K: ToRedisArgs>(&mut self, key: K) -> RedisResult<Vec<Option<isize>>> {
                cmd("MGET").arg(key).query(self)
            }
        }

        /// Implements common redis commands over asynchronous connections.
        /// The return types are concrete and opinionated. If you want to choose the return type you should use the `AsyncCommands` trait.
        #[cfg(feature = "aio")]
        pub trait AsyncTypedCommands : crate::aio::ConnectionLike + Send + Sized {
            $(
                implement_command_async! {
                    $lifetime
                    $(#[$attr])*
                    fn $name<$($tyargs: $ty),*>(
                        $($argname: $argty),*
                    )

                    {
                        $body
                    } $rettype
                }
            )*

            implement_iterators! {
                |c: Cmd, this| Box::pin(async move { c.iter_async(this).await }),
                crate::types::RedisFuture<'_, crate::cmd::AsyncIter<'_, RV>>
            }

            /// Get a value from Redis and convert it to an `Option<isize>`.
            fn get_int<$lifetime, K: ToSingleRedisArg + Send + Sync + $lifetime>(&$lifetime mut self, key: K) -> crate::types::RedisFuture<$lifetime, Option<isize>> {
                Box::pin(async move { cmd("GET").arg(key).query_async(self).await })
            }

            /// Get values from Redis and convert them to `Option<isize>`s.
            fn mget_ints<$lifetime, K: ToRedisArgs + Send + Sync + $lifetime>(&$lifetime mut self, key: K) -> crate::types::RedisFuture<$lifetime, Vec<Option<isize>>> {
                Box::pin(async move { cmd("MGET").arg(key).query_async(self).await })
            }
        }

        /// Implements common redis commands for pipelines.  Unlike the regular
        /// commands trait, this returns the pipeline rather than a result
        /// directly.  Other than that it works the same however.
        impl Pipeline {
            $(
                $(#[$attr])*
                #[inline]
                #[allow(clippy::extra_unused_lifetimes, clippy::needless_lifetimes)]
                pub fn $name<$lifetime, $($tyargs: $ty),*>(
                    &mut self $(, $argname: $argty)*
                ) -> &mut Self {
                    self.add_command($body)
                }
            )*
        }

        // Implements common redis commands for cluster pipelines.  Unlike the regular
        // commands trait, this returns the cluster pipeline rather than a result
        // directly.  Other than that it works the same however.
        #[cfg(feature = "cluster")]
        impl ClusterPipeline {
            $(
                $(#[$attr])*
                #[inline]
                #[allow(clippy::extra_unused_lifetimes, clippy::needless_lifetimes)]
                pub fn $name<$lifetime, $($tyargs: $ty),*>(
                    &mut self $(, $argname: $argty)*
                ) -> &mut Self {
                    self.add_command($body)
                }
            )*
        }
    );
}
