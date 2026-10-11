use crate::{
    Cmd, ErrorKind, Pipeline, RedisError, RedisResult, Value, caching::cache_manager::PrepCacheItem,
};
use std::{iter::zip, time::Instant};

use super::{CacheManager, CacheMode, CachingResult};

/// Holds enough information to resolve Cached Pipeline requests.
pub(crate) struct CacheablePipeline<'a> {
    pub(crate) commands: Vec<CachingResult<'a>>,
    pub(crate) transaction_mode: bool,
}

impl CacheablePipeline<'_> {
    pub(crate) fn resolve(
        self,
        cache_manager: &CacheManager,
        result: Value,
    ) -> RedisResult<Vec<Value>> {
        let replies: Vec<Value> = if self.transaction_mode {
            // With transaction mode, result is contained in an array, so it requires special care.
            let (replies,): (Vec<Value>,) = crate::types::from_redis_value(result)?;
            replies
        } else {
            crate::types::from_redis_value(result)?
        };
        let mut replies = replies.into_iter();

        let mut response = vec![];
        for prepared_cache_result in self.commands {
            match prepared_cache_result {
                CachingResult::Item(PrepCacheItem::Cached(reply)) => response.push(reply),
                CachingResult::Item(PrepCacheItem::NotCached(cacheable_command)) => {
                    let reply = cacheable_command.resolve(cache_manager, &mut replies)?;
                    response.push(reply);
                }
                CachingResult::Item(PrepCacheItem::NotCacheable) | CachingResult::Ignored => {
                    let reply = get_next_reply(&mut replies)?;
                    response.push(reply);
                }
            }
        }
        if self.transaction_mode {
            Ok(vec![Value::Array(response)])
        } else {
            Ok(response)
        }
    }
}

pub(crate) struct SingleCachedCommand<'a> {
    pub(crate) redis_key: &'a [u8],
    pub(crate) cmd_key: &'a [u8],
    pub(crate) cmd: &'a Cmd,
    pub(crate) client_side_expire: Instant,
}

pub(crate) struct MultipleCachedCommandPart<'a> {
    pub(crate) redis_key: &'a [u8],
    pub(crate) cmd_key: Vec<u8>,
}

/// Holds enough information to pack and resolve, both single (GET, HMGET) and multiple (MGET) commands.
pub(crate) enum CacheableCommand<'a> {
    Single(SingleCachedCommand<'a>),
    Multiple {
        command_name: &'a str,
        commands: Vec<(usize, MultipleCachedCommandPart<'a>)>,
        response: Vec<Value>,
        client_side_expire: Instant,
        tail_args: Vec<&'a [u8]>,
    },
}

impl CacheableCommand<'_> {
    pub(crate) fn resolve(
        self,
        cache_manager: &CacheManager,
        mut replies: impl Iterator<Item = Value>,
    ) -> RedisResult<Value> {
        if cache_manager.cache_config.mode == CacheMode::OptIn {
            // Skipping response of CLIENT CACHING YES
            let _ = get_next_reply(&mut replies)?;
        }
        match self {
            CacheableCommand::Single(cached_command) => {
                if let (Some(pttl), Some(reply)) = (replies.next(), replies.next()) {
                    if !matches!(&reply, &Value::ServerError(_)) {
                        cache_manager.insert(
                            cached_command.redis_key,
                            cached_command.cmd_key,
                            reply.clone(),
                            cached_command.client_side_expire,
                            &pttl,
                        );
                    }

                    Ok(reply)
                } else {
                    Err(RedisError::from((
                        ErrorKind::UnexpectedReturnType,
                        "Expected two Value from server",
                    )))
                }
            }
            CacheableCommand::Multiple {
                command_name: _command_name,
                commands,
                response: mut cached_response,
                client_side_expire,
                tail_args: _,
            } => {
                if let Some(Value::Array(mget_values)) = replies.next() {
                    for ((key_value, pttl_value), (key_index, cached_command)) in
                        zip(zip(mget_values, replies), commands)
                    {
                        if !matches!(&key_value, &Value::ServerError(_)) {
                            cache_manager.insert(
                                cached_command.redis_key,
                                &cached_command.cmd_key,
                                key_value.clone(),
                                client_side_expire,
                                &pttl_value,
                            );
                        }
                        cached_response[key_index] = key_value;
                    }
                } else {
                    return Err(RedisError::from((
                        ErrorKind::UnexpectedReturnType,
                        "Expected Value::Array from server",
                    )));
                }
                Ok(Value::Array(cached_response))
            }
        }
    }

    pub(crate) fn pack_command(&self, cache_manager: &CacheManager, pipeline: &mut Pipeline) {
        if cache_manager.cache_config.mode == CacheMode::OptIn {
            let mut cmd = Cmd::new();
            cmd.arg("CLIENT").arg("CACHING").arg("YES");
            pipeline.add_command(cmd);
        }

        match self {
            CacheableCommand::Single(scc) => {
                pipeline.add_command(Cmd::pttl(scc.redis_key));
                pipeline.add_command(scc.cmd.clone());
            }
            CacheableCommand::Multiple {
                command_name,
                commands,
                response: _response,
                client_side_expire: _client_side_expire,
                tail_args,
            } => {
                let mut cmd = Cmd::new();
                cmd.arg(command_name);
                for command in commands {
                    cmd.arg(command.1.redis_key);
                }
                for tail_arg in tail_args {
                    cmd.arg(tail_arg);
                }
                pipeline.add_command(cmd);
                for command in commands {
                    pipeline.add_command(Cmd::pttl(command.1.redis_key));
                }
            }
        }
    }
}

fn get_next_reply(mut replies: impl Iterator<Item = Value>) -> RedisResult<Value> {
    if let Some(reply) = replies.next() {
        Ok(reply)
    } else {
        Err(RedisError::from((
            ErrorKind::UnexpectedReturnType,
            "Expected Value from server",
        )))
    }
}
